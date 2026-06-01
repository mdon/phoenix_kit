defmodule PhoenixKit.Notifications do
  @moduledoc """
  Per-user notifications driven by `PhoenixKit.Activity`.

  When an activity is logged with a `target_uuid` that differs from the
  `actor_uuid`, a row is inserted into `phoenix_kit_notifications` for the
  target user. The user sees it in the bell dropdown (`count_unread/1`,
  `recent_for_user/2`) and in the inbox at `/notifications` (`list_for_user/2`).
  Each row carries its own `seen_at` and `dismissed_at` — the same activity
  can be "seen but not dismissed" for one user and "unseen" for another.

  The whole feature is gated by the global `notifications_enabled` setting
  (default `"true"`); when `"false"`, `maybe_create_from_activity/1` is a no-op.

  Registered as a core toggleable module (`use PhoenixKit.Module`) so it
  appears on the admin Modules page and contributes the `/admin/notifications`
  overview tab. The module enable/disable flips the same
  `notifications_enabled` kill-switch `enabled?/0` reads.
  """

  use PhoenixKit.Module

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Notifications.Events
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Settings

  # ── Creation ─────────────────────────────────────────────────────────

  @doc """
  Inserts a notification for the activity's target user, if the rules allow it.

  Returns one of:
    * `{:ok, %Notification{}}` — row created; broadcast on the per-user topic
    * `{:ok, :skipped}` — filtered out (no target, self-action, feature disabled)
    * `{:error, changeset}` — insert failed (logged, never raised)
  """
  def maybe_create_from_activity(%Entry{} = entry) do
    cond do
      not enabled?() -> {:ok, :skipped}
      is_nil(entry.target_uuid) -> {:ok, :skipped}
      entry.target_uuid == entry.actor_uuid -> {:ok, :skipped}
      not Prefs.user_wants?(entry.target_uuid, entry.action) -> {:ok, :skipped}
      true -> do_create(entry)
    end
  rescue
    e ->
      Logger.warning("Notifications.maybe_create_from_activity failed: #{inspect(e)}")
      {:ok, :skipped}
  end

  defp do_create(%Entry{} = entry) do
    attrs = %{activity_uuid: entry.uuid, recipient_uuid: entry.target_uuid}

    %Notification{}
    |> Notification.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, notification} ->
        # Preload activity so subscribers can render immediately without a roundtrip
        notification = %{notification | activity: entry}
        Events.broadcast(entry.target_uuid, {:notification_created, notification})
        {:ok, notification}

      {:error, %Ecto.Changeset{errors: [{_, {_, opts}} | _]} = cs} ->
        if Keyword.get(opts, :constraint) == :unique do
          # Duplicate insert (retry scenario) — treat as no-op, not an error
          {:ok, :skipped}
        else
          Logger.warning("Notifications insert failed: #{inspect(cs.errors)}")
          {:error, cs}
        end
    end
  end

  @doc """
  Create a **standalone** notification — one not tied to an activity
  (V126). Use for app-driven notices that don't originate from the
  activity log (e.g. "your export is ready").

  `attrs` keys:
    * `:recipient_uuid` (required) — who receives it
    * `:text` / `:icon` / `:link` — convenience, folded into `metadata`
      as `notification_text` / `notification_icon` / `notification_link`
      (the keys `Render` reads)
    * `:metadata` — raw metadata map (merged under the convenience keys)
    * `:type` — optional notification type key (e.g. `"account"`,
      `"posts"`, or a module-contributed type). When given, the send is
      filtered through the recipient's per-type preference
      (`Prefs.user_wants_type?/2`, fail-open).
    * `:action` — optional action string (e.g. `"post.commented"`). When
      given, filtered through `Prefs.user_wants?/2` (which maps the
      action to a type). Use `:type` OR `:action`, not both.

      Notifications.create(%{
        recipient_uuid: user.uuid,
        text: "Your export is ready.",
        icon: "hero-arrow-down-tray",
        link: "/exports/123"
      })

  Honors the global `notifications_enabled` kill-switch. With neither
  `:type` nor `:action`, it's an unconditional app-driven send (no
  preference filtering). Returns `{:ok, %Notification{}}`,
  `{:ok, :skipped}` (disabled or filtered out by prefs), or
  `{:error, changeset}`. Broadcasts `{:notification_created, n}` on success.
  """
  def create(attrs) when is_map(attrs) do
    cond do
      not enabled?() -> {:ok, :skipped}
      not wants_standalone?(attrs) -> {:ok, :skipped}
      true -> do_create_standalone(attrs)
    end
  rescue
    e ->
      Logger.warning("Notifications.create failed: #{inspect(e)}")
      {:ok, :skipped}
  end

  @doc """
  Create a standalone notification for **many** recipients in one call —
  the multi-recipient counterpart to `create/1`. `recipient_uuids` is a
  list; `attrs` is the same shape as `create/1` minus `:recipient_uuid`
  (it's supplied per recipient).

  The recipient list is the caller's responsibility (e.g. the followers
  of an author) — this is the generic fan-out primitive, not an audience
  resolver. Duplicate uuids are de-duped. Each recipient is filtered
  independently through `:type` / `:action` prefs when given, so muted
  users are skipped. Honors the kill-switch once up front.

      Notifications.create_many(follower_uuids, %{
        type: "posts",
        text: "Alice published a new post.",
        link: "/posts/\#{post.id}"
      })

  Returns `{:ok, created_count}` (notifications actually inserted, i.e.
  excluding disabled / pref-skipped) or `{:ok, :skipped}` when
  notifications are globally disabled.
  """
  def create_many(recipient_uuids, attrs) when is_list(recipient_uuids) and is_map(attrs) do
    if enabled?() do
      created =
        recipient_uuids
        |> Enum.uniq()
        |> Enum.count(fn uuid ->
          match?({:ok, %Notification{}}, create(Map.put(attrs, :recipient_uuid, uuid)))
        end)

      {:ok, created}
    else
      {:ok, :skipped}
    end
  end

  # Apply the optional per-recipient preference filter. `:type` checks the
  # type pref directly; `:action` maps the action to a type. With neither,
  # the send is unconditional.
  defp wants_standalone?(%{type: type, recipient_uuid: uuid})
       when is_binary(type) and is_binary(uuid),
       do: Prefs.user_wants_type?(uuid, type)

  defp wants_standalone?(%{action: action, recipient_uuid: uuid})
       when is_binary(action) and is_binary(uuid),
       do: Prefs.user_wants?(uuid, action)

  defp wants_standalone?(_attrs), do: true

  defp do_create_standalone(attrs) do
    metadata =
      (attrs[:metadata] || %{})
      |> put_meta("notification_text", attrs[:text])
      |> put_meta("notification_icon", attrs[:icon])
      |> put_meta("notification_link", attrs[:link])

    %Notification{}
    |> Notification.changeset(%{
      recipient_uuid: attrs[:recipient_uuid],
      activity_uuid: nil,
      metadata: metadata
    })
    |> repo().insert()
    |> case do
      {:ok, notification} ->
        # No activity for a standalone row — pin it nil so Render takes the
        # metadata path (a freshly-inserted struct otherwise carries a
        # NotLoaded association, which Render's activity clause would choke on).
        notification = %{notification | activity: nil}
        Events.broadcast(notification.recipient_uuid, {:notification_created, notification})
        {:ok, notification}

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("Notifications.create insert failed: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end

  defp put_meta(meta, _key, nil), do: meta
  defp put_meta(meta, _key, ""), do: meta
  defp put_meta(meta, key, val), do: Map.put(meta, key, val)

  # ── Reads ────────────────────────────────────────────────────────────

  @doc """
  Returns `{notifications, total_count}` for the given user, newest first.

  Options:
    * `:page` (default 1) / `:per_page` (default 25)
    * `:status` — `:unread` (seen_at nil) | `:all` (default)
    * `:include_dismissed` — include dismissed rows (default `false`)
  """
  def list_for_user(user_uuid, opts \\ []) when is_binary(user_uuid) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    status = Keyword.get(opts, :status, :all)
    include_dismissed = Keyword.get(opts, :include_dismissed, false)

    base_query =
      Notification
      |> where([n], n.recipient_uuid == ^user_uuid)
      |> maybe_filter_dismissed(include_dismissed)
      |> maybe_filter_unread(status)

    total = repo().aggregate(base_query, :count, :uuid)

    rows =
      base_query
      |> order_by([n], desc: n.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo().all()
      |> repo().preload(activity: [:actor])

    {rows, total}
  end

  @doc """
  Returns the N most-recent undismissed notifications for a user.

  Drives the bell dropdown. Activity (and actor) are preloaded.
  """
  def recent_for_user(user_uuid, limit \\ 10) when is_binary(user_uuid) do
    Notification
    |> where([n], n.recipient_uuid == ^user_uuid and is_nil(n.dismissed_at))
    |> order_by([n], desc: n.inserted_at)
    |> limit(^limit)
    |> repo().all()
    |> repo().preload(activity: [:actor])
  end

  @doc "Counts undismissed, unseen notifications for a user. Drives the badge."
  def count_unread(user_uuid) when is_binary(user_uuid) do
    Notification
    |> where(
      [n],
      n.recipient_uuid == ^user_uuid and is_nil(n.seen_at) and is_nil(n.dismissed_at)
    )
    |> repo().aggregate(:count, :uuid)
  rescue
    _ -> 0
  end

  @doc "Fetches one notification scoped to the recipient. Returns `nil` if missing."
  def get_notification(user_uuid, uuid) when is_binary(user_uuid) and is_binary(uuid) do
    Notification
    |> where([n], n.uuid == ^uuid and n.recipient_uuid == ^user_uuid)
    |> repo().one()
    |> maybe_preload()
  end

  defp maybe_preload(nil), do: nil
  defp maybe_preload(%Notification{} = n), do: repo().preload(n, activity: [:actor])

  # ── State transitions ────────────────────────────────────────────────

  @doc """
  Marks a single notification as seen. Idempotent — already-seen rows return
  `{:ok, notification}` unchanged.
  """
  def mark_seen(user_uuid, uuid) when is_binary(user_uuid) and is_binary(uuid) do
    case get_notification(user_uuid, uuid) do
      nil ->
        {:error, :not_found}

      %Notification{seen_at: %DateTime{}} = notification ->
        {:ok, notification}

      %Notification{} = notification ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        notification
        |> Ecto.Changeset.change(seen_at: now)
        |> repo().update()
        |> broadcast_state(user_uuid, :notification_seen)
    end
  end

  @doc "Bulk-marks all unseen notifications as seen. Returns `{count, nil}`."
  def mark_all_seen(user_uuid) when is_binary(user_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Notification
      |> where([n], n.recipient_uuid == ^user_uuid and is_nil(n.seen_at))
      |> repo().update_all(set: [seen_at: now])

    # A bulk-level broadcast lets subscribers refetch; per-row broadcasts would
    # be chatty at scale.
    Events.broadcast(user_uuid, {:notifications_bulk_updated, :seen})
    {count, nil}
  end

  @doc "Dismisses a single notification. Idempotent."
  def dismiss(user_uuid, uuid) when is_binary(user_uuid) and is_binary(uuid) do
    case get_notification(user_uuid, uuid) do
      nil ->
        {:error, :not_found}

      %Notification{dismissed_at: %DateTime{}} = notification ->
        {:ok, notification}

      %Notification{} = notification ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        notification
        |> Ecto.Changeset.change(dismissed_at: now)
        |> repo().update()
        |> broadcast_state(user_uuid, :notification_dismissed)
    end
  end

  @doc "Bulk-dismisses all undismissed notifications. Returns `{count, nil}`."
  def dismiss_all(user_uuid) when is_binary(user_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Notification
      |> where([n], n.recipient_uuid == ^user_uuid and is_nil(n.dismissed_at))
      |> repo().update_all(set: [dismissed_at: now])

    Events.broadcast(user_uuid, {:notifications_bulk_updated, :dismissed})
    {count, nil}
  end

  # ── Retention / pruning ─────────────────────────────────────────────

  @doc "Deletes notifications whose underlying activity is older than `days`."
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      from(n in Notification,
        join: e in Entry,
        on: e.uuid == n.activity_uuid,
        where: e.inserted_at < ^cutoff
      )
      |> repo().delete_all()

    Logger.info("Pruned #{count} notifications older than #{days} days")
    {:ok, count}
  end

  @doc "Retention period in days. Falls back to activity retention if unset."
  def retention_days do
    case Settings.get_setting("notifications_retention_days", nil) do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} when n > 0 -> n
          _ -> fallback_retention()
        end

      _ ->
        fallback_retention()
    end
  rescue
    _ -> fallback_retention()
  end

  defp fallback_retention do
    # Match activity retention when the notifications-specific setting is unset —
    # we never want to outlive the activity we reference (it's cascaded anyway).
    PhoenixKit.Activity.retention_days()
  end

  # ── Module behaviour (toggleable module on the admin Modules page) ────

  @impl PhoenixKit.Module
  def module_key, do: "notifications"

  @impl PhoenixKit.Module
  def module_name, do: "Notifications"

  @impl PhoenixKit.Module
  def enable_system, do: Settings.update_boolean_setting("notifications_enabled", true)

  @impl PhoenixKit.Module
  def disable_system, do: Settings.update_boolean_setting("notifications_enabled", false)

  @impl PhoenixKit.Module
  def get_config, do: Map.merge(%{enabled: enabled?()}, admin_stats())

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "notifications",
      label: "Notifications",
      icon: "hero-bell",
      description: "Per-user in-app notifications driven by the activity log"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_notifications,
        label: "Notifications",
        icon: "hero-bell",
        path: "notifications",
        priority: 640,
        level: :admin,
        permission: "notifications",
        match: :prefix,
        group: :admin_modules,
        gettext_backend: PhoenixKitWeb.Gettext
      )
    ]
  end

  @doc """
  Aggregate counts for the admin overview page: total notifications,
  `unread` (neither seen nor dismissed), and `dismissed`. Rescues to
  zeros so the page never crashes on a query hiccup.
  """
  def admin_stats do
    %{
      total: repo().aggregate(Notification, :count, :uuid),
      unread:
        Notification
        |> where([n], is_nil(n.seen_at) and is_nil(n.dismissed_at))
        |> repo().aggregate(:count, :uuid),
      dismissed:
        Notification
        |> where([n], not is_nil(n.dismissed_at))
        |> repo().aggregate(:count, :uuid)
    }
  rescue
    _ -> %{total: 0, unread: 0, dismissed: 0}
  end

  # ── Settings ─────────────────────────────────────────────────────────

  @doc "Is the notifications feature enabled? Default `true`."
  @impl PhoenixKit.Module
  def enabled? do
    case Settings.get_setting("notifications_enabled", "true") do
      "false" -> false
      false -> false
      _ -> true
    end
  rescue
    _ -> true
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp maybe_filter_dismissed(query, true), do: query
  defp maybe_filter_dismissed(query, false), do: where(query, [n], is_nil(n.dismissed_at))

  defp maybe_filter_unread(query, :unread), do: where(query, [n], is_nil(n.seen_at))
  defp maybe_filter_unread(query, _), do: query

  defp broadcast_state({:ok, notification}, user_uuid, event) do
    notification = repo().preload(notification, activity: [:actor])
    Events.broadcast(user_uuid, {event, notification})
    {:ok, notification}
  end

  defp broadcast_state({:error, _} = err, _user_uuid, _event), do: err

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
