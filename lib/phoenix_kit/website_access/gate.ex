defmodule PhoenixKit.WebsiteAccess.Gate do
  @moduledoc """
  The website password gate: a hard block before anyone sees anything.

  When on, every request that is not the gate's own page gets a blank page
  with one password prompt — no login screen, no front
  page. The password is needed to see the site at all and to reach one's
  own login. The unlock lives in the session as the gate's current EPOCH —
  a random value that carries nothing about the password — and the epoch
  rotates when the password changes, when the gate is switched on, or when
  an admin relocks everyone; a relock is also broadcast so connected
  LiveViews leave. The password itself is a restricted (encrypted) setting,
  readable by the admin who has to tell it to the client and withheld from
  the settings history.

  The gate stands in the browser pipeline: it protects the site's pages.
  Files a host serves outside that pipeline are not behind it.

  Every try is kept (`Attempt`) with a verdict, so a bot at the door can be
  told from a client mistyping. An optional lockout refuses an address after
  N failures in M minutes (off by default — a whole office shares one
  address). The **access link** unlocks without typing, for the client who
  keeps getting it wrong: it is a random token in a restricted setting,
  opened as a page with one button (never a bare GET that unlocks).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.Attempt

  require Logger

  @enabled_key "website_access_gate_enabled"
  @password_key "website_access_password"
  @link_key "website_access_link_token"
  @lockout_attempts_key "website_access_lockout_attempts"
  @lockout_minutes_key "website_access_lockout_minutes"
  @users_pass_key "website_access_gate_users_pass"
  @keep_typed_key "website_access_keep_typed"
  @keep_typed_choices ~w(all near none)
  @epoch_key "website_access_gate_epoch"
  @session_key :website_access_unlock
  @pubsub_topic "phoenix_kit:website_access"
  @close_distance 3

  @doc "The session key the unlock is kept under."
  def session_key, do: @session_key

  @doc "The PubSub topic a relock is broadcast on."
  def pubsub_topic, do: @pubsub_topic

  def enabled_key, do: @enabled_key
  def password_key, do: @password_key
  def link_key, do: @link_key
  def lockout_attempts_key, do: @lockout_attempts_key
  def lockout_minutes_key, do: @lockout_minutes_key
  def users_pass_key, do: @users_pass_key
  def keep_typed_key, do: @keep_typed_key

  @doc """
  What of a try is written down: `"all"` (default — the boss wants to see
  exactly what was typed, the right password and a locked-out try
  included), `"near"` (only the right letters in the wrong case or a typo
  away), `"none"`.
  """
  def keep_typed do
    case Settings.get_setting(@keep_typed_key, "all") do
      value when value in @keep_typed_choices -> value
      _ -> "all"
    end
  end

  def keep_typed_choices, do: @keep_typed_choices

  @doc """
  Whether a logged-in user passes the gate without the password (default:
  yes — they proved more than the password already, and it keeps the admin
  who just changed the password from being thrown out by their own change).
  """
  def users_pass?, do: Settings.get_boolean_setting(@users_pass_key, true)

  @doc "Switching it OFF relocks every session — the ones let in by a login too."
  def set_users_pass(on?, opts \\ []) when is_boolean(on?) do
    with {:ok, _} = ok <- Settings.update_boolean_setting(@users_pass_key, on?, opts) do
      if on?, do: ok, else: relock_everyone(opts)
    end
  end

  @doc """
  Whether the gate is on AND has a password — a gate without a password
  would lock everyone out with no way in, so it is never enforced.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@enabled_key, false) and password_set?()

  @doc "Whether the switch itself is on, password or not (for the settings page)."
  @spec switched_on?() :: boolean()
  def switched_on?, do: Settings.get_boolean_setting(@enabled_key, false)

  @spec password_set?() :: boolean()
  def password_set?, do: password() not in [nil, ""]

  @doc """
  The password, decrypted (a restricted setting). Read through the settings
  cache — it stores the decrypted value and is invalidated on every write —
  because the plug asks on every request while the gate is on.
  """
  @spec password() :: String.t() | nil
  def password, do: Settings.get_setting_cached(@password_key)

  @doc "Sets the password. A changed password relocks every session."
  @spec set_password(String.t() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def set_password(value, opts \\ []) do
    changed? = (value || "") != (password() || "")

    with {:ok, _} = ok <- Settings.update_setting(@password_key, value || "", opts) do
      if changed?, do: relock_everyone(opts), else: ok
    end
  end

  @doc "Switches the gate. Switching it ON relocks every session."
  @spec set_enabled(boolean(), keyword()) :: {:ok, term()} | {:error, term()}
  def set_enabled(on?, opts \\ []) when is_boolean(on?) do
    with {:ok, _} = ok <- Settings.update_boolean_setting(@enabled_key, on?, opts) do
      if on?, do: relock_everyone(opts), else: ok
    end
  end

  # ── Unlock (session) ───────────────────────────────────────────────

  @doc """
  The gate's epoch: a random value every unlocked session carries. It says
  nothing about the password. Rotating it (`relock_everyone/1`) locks every
  session at once; it rotates on its own when the password changes or the
  gate is switched on.
  """
  @spec epoch() :: String.t() | nil
  def epoch do
    case Settings.get_setting_cached(@epoch_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc "Rotates the epoch and tells connected LiveViews to pass the gate again."
  @spec relock_everyone(keyword()) :: {:ok, term()} | {:error, term()}
  def relock_everyone(opts \\ []) do
    with {:ok, _} = ok <- Settings.update_setting(@epoch_key, new_epoch(), opts) do
      broadcast_relock()
      ok
    end
  end

  defp new_epoch, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc "Whether `conn`'s session is unlocked for the current epoch."
  @spec unlocked?(Plug.Conn.t()) :: boolean()
  def unlocked?(%Plug.Conn{} = conn) do
    same_epoch?(Plug.Conn.get_session(conn, @session_key))
  end

  @doc "Whether a LiveView session map (the `session` of `on_mount`) is unlocked."
  @spec session_unlocked?(map()) :: boolean()
  def session_unlocked?(session) when is_map(session) do
    same_epoch?(Map.get(session, Atom.to_string(@session_key)))
  end

  @doc """
  Whether an unlock token taken out of a session earlier (a LiveView keeps
  the one it mounted with) is still the current epoch — i.e. no relock has
  happened since.
  """
  @spec token_current?(term()) :: boolean()
  def token_current?(token), do: same_epoch?(token)

  defp same_epoch?(stored) do
    case epoch() do
      nil -> false
      current -> is_binary(stored) and Plug.Crypto.secure_compare(current, stored)
    end
  end

  @doc """
  Marks `conn`'s session unlocked for the current epoch — minting the first
  epoch if the gate never had one.
  """
  @spec unlock(Plug.Conn.t()) :: Plug.Conn.t()
  def unlock(%Plug.Conn{} = conn) do
    current =
      case epoch() do
        nil ->
          # No epoch yet (a password set without the gate ever switching on):
          # mint one quietly — there is nobody to relock.
          fresh = new_epoch()
          {:ok, _} = Settings.update_setting(@epoch_key, fresh)
          fresh

        value ->
          value
      end

    Plug.Conn.put_session(conn, @session_key, current)
  end

  # ── Verifying a try ────────────────────────────────────────────────

  @doc """
  Judges what was typed against the password: `:correct`, `:case` (the right
  letters, wrong case — caps lock), `:close` (a typo: one edit per four
  characters of the password, at most #{@close_distance}), `:unrelated`, or `:empty`. Constant-time for the exact
  comparison; the distance is only computed after that fails.
  """
  @spec judge(term()) :: :correct | :case | :close | :unrelated | :empty
  def judge(typed) when typed in [nil, ""], do: :empty
  def judge(typed) when not is_binary(typed), do: :unrelated

  def judge(typed) when is_binary(typed) do
    case password() do
      value when is_binary(value) and value != "" and typed != "" ->
        cond do
          not String.valid?(typed) -> :unrelated
          Plug.Crypto.secure_compare(typed, value) -> :correct
          Plug.Crypto.secure_compare(String.downcase(typed), String.downcase(value)) -> :case
          close?(typed, value) -> :close
          true -> :unrelated
        end

      _ ->
        :unrelated
    end
  end

  # How many edits still count as a typo: one per four characters, at most
  # #{@close_distance} — a fixed three would call any three-letter string a
  # near miss of a three-letter password.
  defp close_distance(value),
    do: value |> String.length() |> div(4) |> min(@close_distance) |> max(1)

  @doc """
  Records a try and answers the verdict. What was typed is written down
  according to `keep_typed/0` — everything by default, or only a near miss
  (`:case`/`:close`), or nothing. With `locked: true` the try is refused
  unjudged (verdict `:locked`) but, with "all", still written down.
  """
  @spec attempt(String.t() | nil, keyword()) :: {atom(), Attempt.t() | nil}
  def attempt(typed, meta \\ []) do
    verdict =
      cond do
        Keyword.get(meta, :locked, false) -> :locked
        Keyword.get(meta, :link, false) -> :link
        true -> judge(typed)
      end

    # Nothing is hidden by design (Max): with "all", every try that typed
    # something is written down as typed — the right password included, a
    # try during a lockout included. The setting narrows it, the table's
    # column can be hidden.
    kept =
      case {keep_typed(), verdict} do
        {_, v} when v in [:link, :empty] -> nil
        {"all", _} -> scrub(typed)
        {"near", v} when v in [:case, :close] -> scrub(typed)
        _ -> nil
      end

    # A record that cannot be written must not turn the gate into a 500:
    # the verdict stands, the row is nil, the failure is logged.
    row =
      %Attempt{}
      |> Attempt.changeset(%{
        verdict: Atom.to_string(verdict),
        typed: kept,
        address: Keyword.get(meta, :address),
        user_agent: scrub(Keyword.get(meta, :user_agent))
      })
      |> RepoHelper.repo().insert()
      |> case do
        {:ok, row} ->
          row

        {:error, changeset} ->
          Logger.warning("website access: attempt not recorded: #{inspect(changeset.errors)}")
          nil
      end

    # Pruning counts the table; once in a while is plenty.
    if :rand.uniform(20) == 1, do: prune_attempts()
    {verdict, row}
  end

  # A bot at the door must not fill the disk: the newest `@keep_attempts`
  # rows stay, the rest go.
  @keep_attempts 5000
  # Request headers and params are raw bytes; Postgres `text` is not.
  defp scrub(nil), do: nil
  defp scrub(value) when not is_binary(value), do: nil

  defp scrub(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: value |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
  end

  @doc false
  def prune_attempts do
    count = RepoHelper.repo().aggregate(Attempt, :count)

    if count > @keep_attempts do
      # The cutoff row's uuid breaks ties: rows written in the same
      # microsecond as the cutoff must not go with it (panel finding).
      cutoff =
        Attempt
        |> order_by([a], desc: a.inserted_at, desc: a.uuid)
        |> offset(@keep_attempts)
        |> limit(1)
        |> select([a], {a.inserted_at, a.uuid})
        |> RepoHelper.repo().one()

      # Never a row the lockout might still count: a flood of tries could
      # otherwise push its own failures out and lift the lockout early
      # (panel finding). The cap is exceeded during such a flood, briefly.
      window = NaiveDateTime.add(NaiveDateTime.utc_now(), -lockout_minutes() * 60, :second)

      case cutoff do
        {at, uuid} ->
          RepoHelper.repo().delete_all(
            from(a in Attempt,
              where:
                a.inserted_at < ^window and
                  (a.inserted_at < ^at or (a.inserted_at == ^at and a.uuid <= ^uuid))
            )
          )

        nil ->
          :ok
      end
    end

    :ok
  end

  @doc """
  One try at the door, the lockout check and the record in one step under a
  per-address lock, so a burst of parallel guesses cannot all slip past the
  lockout before any of them is written (panel finding). Returns
  `{:locked, seconds}` or `attempt/2`'s `{verdict, row}`.
  """
  @spec try(String.t() | nil, keyword()) ::
          {:locked, pos_integer()} | {atom(), Attempt.t() | nil}
  def try(typed, meta \\ []) do
    address = Keyword.get(meta, :address)

    RepoHelper.repo().transaction(fn ->
      if address not in [nil, ""] do
        RepoHelper.repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [address])
      end

      case lockout(address) do
        {:locked, seconds} ->
          attempt(typed, Keyword.put(meta, :locked, true))
          {:locked, seconds}

        :ok ->
          attempt(typed, meta)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> raise "website access: try failed: #{inspect(reason)}"
    end
  end

  @doc "The most recent attempts, newest first. `:limit` (default 200)."
  @spec list_attempts(keyword()) :: [Attempt.t()]
  def list_attempts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Attempt
    |> order_by([a], desc: a.inserted_at, desc: a.uuid)
    |> limit(^limit)
    |> RepoHelper.repo().all()
  end

  @doc "Counts by verdict, for the summary line."
  @spec attempt_counts() :: %{String.t() => non_neg_integer()}
  def attempt_counts do
    Attempt
    |> group_by([a], a.verdict)
    |> select([a], {a.verdict, count(a.uuid)})
    |> RepoHelper.repo().all()
    |> Map.new()
  end

  @spec clear_attempts() :: {non_neg_integer(), nil}
  def clear_attempts, do: RepoHelper.repo().delete_all(Attempt)

  # ── Lockout ────────────────────────────────────────────────────────

  @spec lockout_attempts() :: non_neg_integer()
  def lockout_attempts, do: int_setting(@lockout_attempts_key, 0)

  @spec lockout_minutes() :: pos_integer()
  def lockout_minutes, do: max(int_setting(@lockout_minutes_key, 15), 1)

  @doc """
  Whether `address` has failed too often too recently. `{:locked, seconds}`
  with the seconds until the oldest counted failure ages out, or `:ok`.
  Off (always `:ok`) when the attempts setting is 0.
  """
  @spec lockout(String.t() | nil) :: :ok | {:locked, pos_integer()}
  def lockout(address) when address in [nil, ""], do: :ok

  def lockout(address) do
    limit = lockout_attempts()

    if limit <= 0 do
      :ok
    else
      minutes = lockout_minutes()
      since = NaiveDateTime.add(NaiveDateTime.utc_now(), -minutes * 60, :second)

      failures =
        Attempt
        |> where([a], a.address == ^address and a.verdict in ["case", "close", "unrelated"])
        |> where([a], a.inserted_at >= ^since)
        |> order_by([a], desc: a.inserted_at)
        |> limit(^limit)
        |> select([a], a.inserted_at)
        |> RepoHelper.repo().all()

      if length(failures) >= limit do
        oldest = List.last(failures)
        ends_at = NaiveDateTime.add(oldest, minutes * 60, :second)
        {:locked, max(NaiveDateTime.diff(ends_at, NaiveDateTime.utc_now(), :second), 1)}
      else
        :ok
      end
    end
  end

  # ── Access link ────────────────────────────────────────────────────

  @doc "The access link token, or nil when none has been made."
  @spec access_link_token() :: String.t() | nil
  def access_link_token do
    case Settings.get_setting_cached(@link_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc "Makes a new token (replacing any old one — old links stop working)."
  @spec regenerate_access_link(keyword()) :: {:ok, String.t()} | {:error, term()}
  def regenerate_access_link(opts \\ []) do
    token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    case Settings.update_setting(@link_key, token, opts) do
      {:ok, _} -> {:ok, token}
      error -> error
    end
  end

  @spec revoke_access_link(keyword()) :: {:ok, term()} | {:error, term()}
  def revoke_access_link(opts \\ []), do: Settings.update_setting(@link_key, "", opts)

  @doc "Whether `key` is the current access link token."
  @spec access_link_valid?(String.t() | nil) :: boolean()
  def access_link_valid?(key) when is_binary(key) and key != "" do
    case access_link_token() do
      nil -> false
      token -> Plug.Crypto.secure_compare(token, key)
    end
  end

  def access_link_valid?(_), do: false

  # ── Relock ─────────────────────────────────────────────────────────

  @doc "Tells connected LiveViews the gate changed: they must pass it again."
  def broadcast_relock, do: PubSubManager.broadcast(@pubsub_topic, {:website_access, :relock})

  def subscribe, do: PubSubManager.subscribe(@pubsub_topic)

  # ── Helpers ────────────────────────────────────────────────────────

  defp int_setting(key, default) do
    case Integer.parse(Settings.get_setting(key, Integer.to_string(default))) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  # Levenshtein distance between two short strings (a password and a try —
  # the try is capped, so the plain quadratic table is fine).
  # The edit distance is only worth computing when the lengths are close:
  # a megabyte of junk (or a bot's random string) is unrelated at once.
  defp close?(typed, value) do
    allowed = close_distance(value)
    typed_length = String.length(typed)
    value_length = String.length(value)

    abs(typed_length - value_length) <= allowed and typed_length <= 255 and
      distance(typed, value) <= allowed
  end

  # Plain Levenshtein over graphemes; rows are tuples so a cell is O(1).
  defp distance(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)
    first_row = List.to_tuple(Enum.to_list(0..length(b)))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {ca, i}, prev ->
      {row, _left} =
        b
        |> Enum.with_index(1)
        |> Enum.reduce({[i], i}, fn {cb, j}, {acc, left} ->
          diag = elem(prev, j - 1)
          up = elem(prev, j)
          cost = if ca == cb, do: 0, else: 1
          cell = Enum.min([left + 1, up + 1, diag + cost])
          {[cell | acc], cell}
        end)

      row |> Enum.reverse() |> List.to_tuple()
    end)
    |> then(&elem(&1, tuple_size(&1) - 1))
  end
end
