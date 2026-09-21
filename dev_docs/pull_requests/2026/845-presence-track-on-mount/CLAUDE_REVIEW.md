# PR #845: Track presence for every LiveView mounted through PhoenixKit's on_mount hooks

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`844be15a`), not yet released; review only, no fixes applied
**Date**: 2026-09-21

## Goal

Before this PR, only a few admin pages (Live sessions, the dashboard overview)
tracked a visitor's presence themselves. The PR moves tracking into the shared
scope mount in `PhoenixKitWeb.Users.Auth`. Every connected, authenticated
LiveView mounted through a scope hook — admin, feature modules, and host pages —
now shows up in "Live sessions". `current_page` is updated on each path change.
`SimplePresence` rows are keyed by `(user, session)` and hold a set of monitors,
so several tabs share one row. The session id is a SHA-256 digest of the
session token rather than the reversible `live_socket_id`.

## Verified

- A disconnected (static) render never tracks. Only `connected?` mounts
  create a row, so a thrown-away first render cannot leave a row behind.
- `maybe_track_presence/1` is guarded by `:phoenix_kit_presence_tracked?`, so
  a live_session with `:phoenix_kit_mount_current_scope` followed by an
  `:phoenix_kit_ensure_*` hook tracks once.
- The `:current_page` hook (`set_routing_info/3`) is attached by the same scope
  mount, so every tracked socket also gets its page updates. A query-string-only
  patch is skipped.
- `catch :exit` on `track_*` and `update_metadata/2` keeps a dead or
  not-yet-started `SimplePresence` from failing a page. `exit_class/1` logs only
  the class, never the request carrying `session_id`/`ip_address`/`user_agent`.
- Test run against the sandbox DB: `simple_presence_test.exs`,
  `live_sessions_presence_test.exs` and `auth_flows_test.exs` — 94 tests, 0
  failures. `auth_flows_test.exs` dropped its `start_supervised!(SimplePresence)`
  setup. That is safe now that tracking catches the missing process.

## Findings

### IMPROVEMENT - HIGH: One page change in a single tab reports a disconnect and a new connect

On a `live_redirect`/`push_navigate`, the LiveView client destroys the old root
view — leaving its channel — **before** it joins the new one
(`LiveSocket.replaceMain/4`: `oldMainView.destroy()` then
`this.main.join(...)`). The old process exits, and `SimplePresence` gets its
`:DOWN` while the new process is still in `mount` (it has to load the scope
before it reaches `maybe_track_presence/1`). With one tab open, that `:DOWN` is
the row's last monitor, so:

1. the row is deleted and `{:user_session_disconnected, ...}` is broadcast;
2. the new mount's `track_user/2` gets `:new`, broadcasts
   `{:user_session_connected, ...}`, and `connected_at` restarts.

Before this PR the same thing happened only on the two admin pages that tracked
themselves. Now it happens on every navigation between LiveViews, on every
tracked page of the site. Effects:

- "Live sessions" and the dashboard overview reload their list/stats twice for
  every page change of every signed-in visitor (both handlers re-read the table
  on these events).
- `connected_at` means "when the current LiveView mounted", not "when the
  visitor arrived". The moduledoc's "`connected_at` is pinned to the row's
  first appearance" holds only while a second tab keeps the row alive.
- Any future consumer of the connect/disconnect events (activity, analytics)
  would count page views as sessions.

**Suggested fix:** delay the removal when the last monitor goes down. Have
`cleanup_session_by_monitor/1` mark the row as pending (empty monitor set) and
`Process.send_after(self(), {:expire, key}, grace_ms)` (a few seconds). A
`track` within that window finds the row and returns `:existing`, so nothing is
broadcast and `connected_at` is kept. `{:expire, key}` deletes and broadcasts
only if the monitor set is still empty. The hourly sweep then has a real job
(see NITPICK below).

### IMPROVEMENT - MEDIUM: Presence work is now linear in the number of rows on every mount, navigation and page close

Tracking went from a few admin pages to every signed-in page view, but the
per-event cost did not change:

- Each `track_*`/`update_metadata` call is followed by
  `broadcast_presence_stats/0` in the **caller**: `get_presence_stats/0` reads the
  whole table (`:ets.tab2list/1`), sorts it and groups it by page, then
  broadcasts. That runs on every connected mount and every path change, whether
  or not anyone is subscribed to the presence topic.
- Each `:DOWN` is handled **inside the GenServer** by
  `cleanup_session_by_monitor/1`, which scans the whole table to find the row
  that holds that monitor ref, and then computes and broadcasts the stats again.
  Every page close holds up every other page's `track` call behind a full scan.

With N signed-in visitors this is O(N) (stats: O(N log N)) per page view,
serialised partly through one process. It is harmless on an admin-sized
audience and noticeable on a busy host site.

**Suggested fix:** keep a `monitor_ref => key` map in the GenServer state (make
the `:DOWN` lookup O(1)), and coalesce stats broadcasts — mark the stats dirty
and send at most one `presence_stats_updated` per interval (e.g. 1 s) from the
GenServer, instead of one per event from each caller. The table could also be
created with `read_concurrency: true`, since the list/stats readers bypass the
GenServer.

### IMPROVEMENT - MEDIUM: The dashboard overview's fallback tracking still stores the reversible `live_socket_id`

`PhoenixKitWeb.Live.Dashboard.Overview.track_authenticated_session/3` still uses
`session["live_socket_id"]` as the `session_id`. That value is
`"phoenix_kit_sessions:" <> Base.url_encode64(token)` — the raw session token,
reversible. The PR's own comment in `presence_session_id/1` explains why it
must not be in presence rows or their PubSub payloads, and the moduledoc lists
this call site as not yet updated. The path is reached only when a host route
calls `assign_overview/3` without going through a scope hook, so it is rare.
When it is reached, the token sits in the ETS row and in the
`user_session_connected` broadcast. It also produces a second row for the same
login (a different id from the hook's digest).

**Suggested fix:** make the digest a shared public helper (e.g.
`Presence.session_id_for_token/1`) and use it from both
`Auth.maybe_track_presence/1` and `Overview`, reading
`socket.assigns[:phoenix_kit_session_token]`.

### NITPICK: The logout disconnect names a session id no row uses

`Auth.log_out_user/1` broadcasts
`{:user_session_disconnected, uuid, session_id}` with
`extract_session_id_from_live_socket_id/1` (the first 8 chars of the encoded
token). Presence rows now use the SHA-256 digest, so the id in that event never
matches a row. Nothing breaks: both subscribers ignore the id and reload from
the table, and the socket disconnect that follows removes the row through its
`:DOWN`. It is misleading for any consumer that trusts the id, and it still
puts a token prefix in a PubSub payload. Use the same digest here.

### NITPICK: The hourly sweep can no longer remove anything

`cleanup_old_sessions/0` removes only rows with **zero** monitors, but
`cleanup_session_by_monitor/1` deletes a row as soon as its last monitor goes
down, so no row with zero monitors exists. The sweep is dead code as written.
Its remaining effect is a `presence_stats_updated` broadcast every 5 minutes
when the table is not empty. It becomes useful again as the backstop for the
grace-period rows suggested in the HIGH finding.

## Not an issue

- Two monitors on one process (the hook plus a page's own tracking call) are
  fine: both `:DOWN`s arrive and each removes its own ref.
- `update_current_page/3` with `session_id: nil` (no session token on the
  socket) uses `user_key(uuid, nil)`, the same key `track_user/2` used for that
  socket, so it still finds the row.
