# Notifications

Moved from `AGENTS.md` 2026-07-27 — a short operational summary stayed
there; this is the full reference.

Per-user inbox, driven by activity log. When `Activity.log/1` records an entry with `target_uuid != actor_uuid`, a row goes into `phoenix_kit_notifications` for the target user. Admins use `/admin/activity` for audit — they do NOT receive notifications.

Kill switch: `notifications_enabled` setting (default `"true"`).

**Generation:** automatic — never insert directly into `phoenix_kit_notifications`; create the activity and let the hook in `lib/phoenix_kit/activity/activity.ex` fan out via `PhoenixKit.Notifications.maybe_create_from_activity/1`. Each row is `(activity_uuid, recipient_uuid)` with independent `seen_at`/`dismissed_at`.

**Rendering:** `PhoenixKit.Notifications.Render.render(notification)` → `%{icon, text, link, actor_uuid}`. Unknown actions fall back to the raw action string.

**Public API** (`PhoenixKit.Notifications`):
- `list_for_user(user_uuid, opts)` — `:page`, `:per_page`, `:status (:unread|:all)`, `:include_dismissed`
- `recent_for_user(user_uuid, limit \\ 10)`, `count_unread(user_uuid)`
- `mark_seen` / `mark_all_seen` / `dismiss` / `dismiss_all` (all `(user_uuid, ...)`)
- `get_notification(user_uuid, uuid)` — recipient-scoped
- `enabled?/0`, `retention_days/0`, `prune/1`

**PubSub topic:** `PhoenixKit.Notifications.Events.topic_for_user(user_uuid)` (`"phoenix_kit:notifications:<uuid>"`). Events: `{:notification_created, n}`, `{:notification_seen, n}`, `{:notification_dismissed, n}`, `{:notifications_bulk_updated, :seen | :dismissed}`.

**UI** — no PhoenixKit-owned notifications page. Embeddable bell `PhoenixKitWeb.Live.NotificationsBell` (sticky nested LV, owns its PubSub sub):

```heex
<%= Phoenix.Component.live_render(@socket, PhoenixKitWeb.Live.NotificationsBell,
      id: "pk-notifications-bell", sticky: true,
      session: %{"user_uuid" => @current_user.uuid}) %>
```

"Seen" only on explicit user action — opening the dropdown does NOT auto-mark seen.

**Per-user preferences:** users mute notification *types* (not actions) via `UserSettings`. Persisted in `users.custom_fields["notification_preferences"]` (V18 JSONB column). Types live in `PhoenixKit.Notifications.Types`. Core types: `"account"`, `"posts"`, `"comments"`. External modules contribute via optional `notification_types/0` on `PhoenixKit.Module`:

```elixir
@impl PhoenixKit.Module
def notification_types do
  [%{key: "reviews", label: "Reviews", description: "...",
     actions: ["review.submitted", "review.edited"], default: true}]
end
```

`Types.list/0` merges core + modules; toggle appears automatically. `Notifications.Prefs.user_wants?/2` is **fail-open** — unknown actions, missing prefs, or lookup errors return `true`.

**Custom display:** `Render.render/1` honors three metadata keys before falling back:

```elixir
metadata: %{
  "notification_text" => "Alice left you a 5-star review.",
  "notification_icon" => "hero-star",
  "notification_link" => "/reviews/#{review.uuid}"
}
```

Any key can be absent — Render falls back to the action lookup for the missing parts.

## Delivery channels (external destinations)

Pluggable per-user routing of notifications to **external** destinations
(Telegram, Email; more via modules) on top of the in-app inbox. **Model B —
parallel routing layer**: the inbox path above is untouched; external channels
are computed + enqueued independently, so "Telegram on, inbox off" works with
**no migration** (config rides `users.custom_fields`).

- **`PhoenixKit.Notifications.Channel`** behaviour: `key/0`, `label/0`, `icon/0`,
  `configured?/2`, `deliver/2`, optional `validate_config/1`. `deliver/2` takes a
  channel-neutral, pre-rendered `t:envelope/0` (absolute URL) and returns a
  permanent/transient error taxonomy so the worker decides retry-vs-give-up.
- **`Channels`** registry: core `[Email, Telegram]` + modules' optional
  `notification_channels/0` (same merge as `Types`). `Channels.Email` is
  always-configured (sends via `Mailer`); `Channels.Telegram` auto-discovers the
  recipient's Telegram connections + captured `chat_ids`.
- **`ChannelConfig`** — per-channel config under
  `custom_fields["notification_channel:<key>"]` (ONE top-level key per channel so
  the atomic shallow `||` merge can't clobber siblings). Reserved: `enabled`
  (default on), `types` (**fail-closed** per-type opt-in), `cadences`.
- **`Routing`** — `targets_for_action/2` / `targets_for_type/2` / `any_target?/2`,
  **fail-closed**: untyped / standalone sends never route out.
- **Delivery**: `DeliveryWorker` on a dedicated `:notifications` Oban queue
  (enqueued at creation for immediate cadences; the inbox insert is **decoupled**
  from the enqueue, so a failed channel enqueue never costs the user their inbox
  row). `DigestWorker` is an Oban cron (one entry per cadence: immediate / hourly
  / 12h / daily / weekly) that counts activity in a fixed window and sends one
  summary — no per-user last-sent state.
- **Telegram setup** lives on the personal integration form (mode select + chat
  capture folded into Test), NOT the notifications page. `mode`: `"single"` (lock
  one chat) / `"multi"` (broadcast to all who started the bot); an **Unlink**
  button clears captured `chat_ids`. The `notification_channel:telegram` config
  holds only routing/cadence — connection + chat live on the integration.

**Cleanup:** `PhoenixKit.Notifications.PruneWorker` daily (`"0 4 * * *"`). Retention: `notifications_retention_days` → falls back to `activity_retention_days` (default 90). Cascading FK deletes also remove notifications when the underlying activity is pruned.
