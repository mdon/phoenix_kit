defmodule PhoenixKit.Users.LoginAttempts do
  @moduledoc """
  Recording and reading sign-ins that did NOT succeed.

  Before this existed, a wrong password produced a flash and nothing else — no
  row, no activity entry, nothing either the targeted account holder or the
  site owner could ever see. The only trace was Hammer's in-memory rate-limit
  counter, which is node-local, lost on restart, counts successes too, and
  says nothing at all until a bucket overflows.

  The case that motivates it: an attacker who guesses correctly on attempt 400
  triggers only the new-device email, which is indistinguishable from "I signed
  in from my new laptop". The 399 failures before it are the one signal that
  tells those two apart.

  ## Rows are aggregated, not one-per-attempt

  `record/4` upserts into the unique key
  `(identifier, ip_network, outcome, bucket_start)`, where `bucket_start` is
  the current hour. A sustained attack against one account from one network
  collapses into a single row per hour whose `attempt_count` rises, so the
  table cannot be grown by attacker effort along that axis.

  It CAN still be grown along the identifier axis — an attacker spraying
  distinct addresses writes one row each. That is bounded by the rate limiter
  in front of it (`login_limit * 3` per IP network per minute, so ~900
  rows/hour/network at the default) and by retention, but it is the price of
  storing the identifier verbatim, which is what makes "someone is hammering
  `admin@`" visible. Requests the limiter REFUSES are past that bound, so a
  `"rate_limited"` row keeps its identifier only when it names a real account
  and is otherwise stored as `"*"` — one row per network per hour.

  Write is one statement with no preceding read, so concurrent attempts never
  contend on a row lock.

  ## It must never block a sign-in

  Every public entry point swallows its failures. `rescue` alone is not enough:
  an unreachable database RAISES on an unowned checkout but EXITS on a dead
  pool, so the write path catches both. A security log that takes the login
  form down with it is worse than no security log.

  ## It must not become an account-existence oracle

  `record/4` runs on every failing branch and the HTTP response is unchanged by
  it — only what is stored differs. The two branches that share the deliberately
  generic "Invalid email/username or password" flash both perform the same
  lookup, so neither the response nor the work done distinguishes a real
  account from a fictitious one.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.LoginAttempt
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKit.Utils.UserAgent

  # The same cap `PhoenixKitWeb.Users.Session` already applies before echoing
  # the identifier back into a flash, and the column width in V197.
  @identifier_max 160

  # The alert window, the default burst size, and how long one alert silences
  # the next for that account.
  @alert_window_hours 1
  @default_threshold 10
  @alert_cooldown_seconds 24 * 3600
  @alert_stamp_key "phoenix_kit_failed_login_alert_at"
  # What a refused request's identifier is stored as when it names no account.
  @collapsed_identifier "*"

  @doc """
  Whether failed sign-ins are recorded (setting `login_attempt_logging_enabled`,
  default `true`).

  Unlike `new_login_alert_enabled`, this defaults ON: it writes one bounded row
  and sends nothing, and the data is useless retroactively — an install that
  turns it on after an incident has already lost the evidence.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("login_attempt_logging_enabled", true)

  @doc """
  Records one failed sign-in from `conn`.

  `identifier` is whatever the person typed in the email/username field.
  `outcome` is one of `PhoenixKit.Users.LoginAttempt.outcomes/0`.

  Pass `:user` in `opts` when the caller already holds the account (the
  inactive-account branch does), to save a lookup.

  Always returns `:ok`. Never raises, never exits.
  """
  @spec record(Plug.Conn.t(), String.t() | nil, String.t(), keyword()) :: :ok
  def record(conn, identifier, outcome, opts \\ []) do
    if enabled?() do
      conn |> do_record(identifier, outcome, opts) |> maybe_alert()
    end

    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAttempts] record failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[PhoenixKit.LoginAttempts] record exited: #{inspect(reason)}")
      :ok
  end

  defp do_record(conn, identifier, outcome, opts) do
    identifier = normalize_identifier(identifier)
    user = resolve_user(identifier, opts)
    identifier = stored_identifier(identifier, user, outcome)
    ip_address = IpAddress.extract_from_conn(conn)
    ua = user_agent_header(conn)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      user_uuid: user && user.uuid,
      identifier: identifier,
      ip_address: ip_address,
      # `network/1` returns nil for an address it cannot parse ("unknown" from
      # a conn with no usable peer), but the column is NOT NULL and the value
      # is a dedup key component — so an unparseable address groups as itself.
      ip_network: IpAddress.network(ip_address) || ip_address,
      user_agent_hash: SessionFingerprint.hash_user_agent(conn),
      browser: UserAgent.browser(ua),
      os: UserAgent.os(ua),
      outcome: outcome,
      attempt_count: 1,
      bucket_start: bucket_start(now),
      first_at: now,
      last_at: now
    }

    # An invalid changeset (or a constraint the upsert cannot satisfy) must
    # not still fire the alert: that would warn about a row we did not write.
    case upsert(attrs, now) do
      {:ok, _} -> user
      {:error, _} -> nil
    end
  end

  @doc """
  The bucket upsert, extracted so a test can run the real statement rather
  than a copy that drifts from it.

  `opts` reaches `Repo.insert/2`; `test/integration/prefix_migration_test.exs`
  passes `prefix:` to prove the `EXCLUDED` fragment below survives a
  named-schema install, which the `public` path cannot demonstrate.
  """
  @spec upsert(map(), DateTime.t(), keyword()) ::
          {:ok, LoginAttempt.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs, %DateTime{} = now, opts \\ []) do
    %LoginAttempt{}
    |> LoginAttempt.changeset(attrs)
    |> RepoHelper.repo().insert(
      Keyword.merge(
        [
          # `first_at` is deliberately absent: it must keep saying when this
          # bucket opened, not when it was last touched.
          #
          # `user_uuid` uses COALESCE so a bucket that opened against an
          # unknown identifier (the account did not exist yet) attaches once
          # the account appears, instead of staying "no such account" for the
          # rest of the hour.
          #
          # `EXCLUDED` is a Postgres keyword for the proposed row, NOT a
          # relation, so it must never be schema-qualified.
          on_conflict:
            from(a in LoginAttempt,
              update: [
                inc: [attempt_count: 1],
                set: [
                  last_at: ^now,
                  user_uuid: fragment("COALESCE(?, EXCLUDED.user_uuid)", a.user_uuid)
                ]
              ]
            ),
          conflict_target: [:identifier, :ip_network, :outcome, :bucket_start]
        ],
        opts
      )
    )
  end

  # A refused request is not bounded by the rate limiter — it IS the limiter
  # refusing — so its identifier must not be a free dedup-key component: a
  # blocked client naming a fresh address per request would write a row per
  # request. One that names a real account keeps it (that is the "someone is
  # hammering admin@" signal); anything else collapses into one row per
  # network per hour.
  defp stored_identifier(_identifier, nil, "rate_limited"), do: @collapsed_identifier
  defp stored_identifier(identifier, _user, _outcome), do: identifier

  # The caller knows the account only on the inactive branch. Everywhere else
  # `Auth` collapses "no such user" and "wrong password" into one return value
  # on purpose, so the lookup happens here rather than by widening that API.
  # Same resolver the login form uses, so an identifier with `@` cannot attach
  # to a username that happens to equal some other account's email.
  defp resolve_user(identifier, opts) do
    case Keyword.get(opts, :user) do
      %User{} = user -> user
      _ -> lookup_user(identifier)
    end
  end

  defp lookup_user(""), do: nil
  defp lookup_user(identifier), do: Auth.get_user_by_email_or_username(identifier)

  @doc """
  Whether a burst of failures warns the account holder
  (`failed_login_alert_enabled`, default `false`).

  Defaults OFF because it sends mail, matching `new_login_alert_enabled`.
  """
  @spec alerts_enabled?() :: boolean()
  def alerts_enabled?, do: Settings.get_boolean_setting("failed_login_alert_enabled", false)

  @doc "Failures inside #{@alert_window_hours}h that trigger an alert (default #{@default_threshold})."
  @spec alert_threshold() :: pos_integer()
  def alert_threshold do
    case Settings.get_setting("failed_login_alert_threshold", "#{@default_threshold}") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> @default_threshold
        end

      _ ->
        @default_threshold
    end
  rescue
    _ -> @default_threshold
  catch
    :exit, _ -> @default_threshold
  end

  # Nothing to warn about for an identifier that matches no account, and
  # nothing to warn anyone with when the feature is off.
  defp maybe_alert(nil), do: :ok

  defp maybe_alert(%User{} = user) do
    if alerts_enabled?(), do: do_alert(user)
    :ok
  end

  defp do_alert(%User{} = user) do
    window_start = DateTime.add(DateTime.utc_now(), -@alert_window_hours * 3600, :second)
    count = count_for_user_since(user, window_start)

    # The cap is the point: an attacker who keeps going must not be able to
    # turn this into a mail flood against the person they are attacking.
    # Stamp MUST succeed before the send: a stamp that fails (user gone,
    # custom_fields rejected) would otherwise retry on every subsequent
    # failure and become the flood.
    #
    # `alert_due?/1` reads a struct loaded before this attempt was written, so
    # it is only a cheap early-out. The STAMP is the gate: it is one
    # conditional UPDATE, and of any number of concurrent failures exactly one
    # wins it.
    if count >= alert_threshold() and alert_due?(user) and stamp_alert(user) == :stamped do
      UserNotifier.deliver_failed_login_alert(user, %{
        count: count,
        window_hours: @alert_window_hours
      })
    end

    :ok
  end

  defp alert_due?(%User{custom_fields: fields}) do
    case Map.get(fields || %{}, @alert_stamp_key) do
      stamp when is_binary(stamp) ->
        case DateTime.from_iso8601(stamp) do
          {:ok, at, _} ->
            DateTime.diff(DateTime.utc_now(), at, :second) >= @alert_cooldown_seconds

          _ ->
            true
        end

      _ ->
        true
    end
  end

  # Stamped BEFORE the send, not after: a send that raises must still burn the
  # cooldown, or every subsequent failure retries it.
  #
  # Compare-and-set in one statement: the row is stamped only while its stamp
  # is absent or older than the cooldown, so a parallel burst that all read
  # "due" from their own stale structs still sends ONE mail. An unconditional
  # merge here let every one of them through. The stamps are fixed-width UTC
  # ISO 8601 strings, which order as text.
  #
  # A JSONB merge and never a whole-map replace — a replace built from a struct
  # held in memory restores every other key's old value. `updated_at` is left
  # alone and nothing is broadcast: an anonymous failed sign-in is not an edit
  # of the account.
  defp stamp_alert(%User{uuid: uuid}) do
    now = DateTime.utc_now()
    cutoff = now |> DateTime.add(-@alert_cooldown_seconds, :second) |> DateTime.to_iso8601()
    stamp = %{@alert_stamp_key => DateTime.to_iso8601(now)}

    query =
      from(u in User,
        where: u.uuid == ^uuid,
        where:
          fragment(
            "(COALESCE(?, '{}'::jsonb) ->> ?) IS NULL OR (? ->> ?) < ?",
            u.custom_fields,
            ^@alert_stamp_key,
            u.custom_fields,
            ^@alert_stamp_key,
            ^cutoff
          ),
        update: [
          set: [
            custom_fields:
              fragment("COALESCE(?, '{}'::jsonb) || ?", u.custom_fields, type(^stamp, :map))
          ]
        ]
      )

    case RepoHelper.repo().update_all(query, []) do
      {1, _} -> :stamped
      _ -> :not_due
    end
  end

  @doc """
  Normalizes an identifier the way it is stored: trimmed, downcased, and
  truncated to #{@identifier_max} characters.

  Truncation is not cosmetic — the field is attacker-controlled and otherwise
  unbounded.
  """
  @spec normalize_identifier(String.t() | nil) :: String.t()
  def normalize_identifier(nil), do: ""

  def normalize_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.replace("\0", "")
    |> String.trim()
    |> String.downcase()
    |> truncate_identifier()
  end

  # `varchar(160)` counts Postgres characters (codepoints). `String.slice/2`
  # counts graphemes, and a grapheme can be several codepoints — 160 emoji
  # with ZWJ sequences would overflow the column and the insert would raise
  # rather than record.
  defp truncate_identifier(identifier) do
    identifier
    |> String.codepoints()
    |> Enum.take(@identifier_max)
    |> List.to_string()
  end

  @doc "The hour `at` falls in — the dedup bucket."
  @spec bucket_start(DateTime.t()) :: DateTime.t()
  def bucket_start(%DateTime{} = at) do
    %{at | minute: 0, second: 0, microsecond: {0, 0}}
  end

  @doc """
  How many failed attempts `user` has accumulated since `since`.

  Sums `attempt_count`, because one row is many attempts. Returns 0 rather
  than raising if the table cannot be read.
  """
  @spec count_for_user_since(User.t() | UUIDv7.t(), DateTime.t()) :: non_neg_integer()
  def count_for_user_since(%User{uuid: uuid}, since), do: count_for_user_since(uuid, since)

  def count_for_user_since(uuid, %DateTime{} = since) when is_binary(uuid) do
    RepoHelper.repo().one(
      from(a in LoginAttempt,
        where: a.user_uuid == ^uuid and a.last_at >= ^since,
        select: coalesce(sum(a.attempt_count), 0)
      )
    ) || 0
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc """
  The most recent failed-attempt buckets for `user`, newest first.
  """
  @spec recent_for_user(User.t() | UUIDv7.t(), keyword()) :: [LoginAttempt.t()]
  def recent_for_user(user, opts \\ [])
  def recent_for_user(%User{uuid: uuid}, opts), do: recent_for_user(uuid, opts)

  def recent_for_user(uuid, opts) when is_binary(uuid) do
    limit = Keyword.get(opts, :limit, 10)

    RepoHelper.repo().all(
      from(a in LoginAttempt,
        where: a.user_uuid == ^uuid,
        order_by: [desc: a.last_at],
        limit: ^limit
      )
    )
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Site-wide totals since `since`, for the admin view.

  `attempts` sums `attempt_count` (what actually happened); `buckets` counts
  rows (how the total is spread); `accounts` and `networks` count distinct
  targets and sources.
  """
  @spec stats(DateTime.t()) :: %{
          attempts: non_neg_integer(),
          buckets: non_neg_integer(),
          accounts: non_neg_integer(),
          networks: non_neg_integer()
        }
  def stats(%DateTime{} = since) do
    RepoHelper.repo().one(
      from(a in LoginAttempt,
        where: a.last_at >= ^since,
        select: %{
          attempts: coalesce(sum(a.attempt_count), 0),
          buckets: count(a.uuid),
          accounts: count(a.user_uuid, :distinct),
          networks: count(a.ip_network, :distinct)
        }
      )
    ) || empty_stats()
  rescue
    _ -> empty_stats()
  catch
    :exit, _ -> empty_stats()
  end

  defp empty_stats, do: %{attempts: 0, buckets: 0, accounts: 0, networks: 0}

  @doc """
  The heaviest failed-attempt buckets since `since`, newest and largest first.

  Rows carry an attacker-controlled `identifier` — escape it when rendering.
  """
  @spec top_since(DateTime.t(), keyword()) :: [LoginAttempt.t()]
  def top_since(%DateTime{} = since, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    RepoHelper.repo().all(
      from(a in LoginAttempt,
        where: a.last_at >= ^since,
        order_by: [desc: a.attempt_count, desc: a.last_at],
        limit: ^limit,
        preload: [:user]
      )
    )
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "The configured retention period in days (`login_attempt_retention_days`, default 90)."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case Settings.get_setting("login_attempt_retention_days", "90") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {days, _} when days > 0 -> days
          _ -> 90
        end

      _ ->
        90
    end
  rescue
    _ -> 90
  catch
    :exit, _ -> 90
  end

  @doc "Deletes buckets last touched more than `days` ago."
  @spec prune(pos_integer()) :: {:ok, non_neg_integer()}
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      from(a in LoginAttempt, where: a.last_at < ^cutoff)
      |> RepoHelper.repo().delete_all()

    Logger.info("Pruned #{count} login attempt buckets older than #{days} days")
    {:ok, count}
  end

  defp user_agent_header(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end
end
