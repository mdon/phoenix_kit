# Claude Review — PR #761

**Branch:** `leaf-0.6.0-and-fixes` (alexdont)
**Merge commit:** `2198bd50` (parent `b153b0a6`)
**Verdict:** Approve, with one bug fixed post-merge
**Reviewer:** Claude (Sonnet 5)

## Summary

Three unrelated changes bundled together: (1) pins the Leaf JS bundle to
0.6.0 and adds a test that holds the CDN pin and the Hex lock together, (2)
replaces three drifted copies of the language-switcher URL builder
(`AdminNav`, `LayoutWrapper`, `UserDashboardNav`) with one
`Routes.locale_switch_path/3` that fixes a real stacking-prefix bug, (3)
adds a rotating greeting to the admin dashboard welcome block.

(1) and (2) are correct and well-tested. (3) had a real bug: `mount/3` runs
twice per page load and the greeting was drawn fresh on each pass, so the
greeting visibly changed the instant the websocket connected — on nearly
every load. Fixed below.

## Findings

### BUG - MEDIUM: dashboard greeting rerolls on socket connect

`lib/phoenix_kit_web/live/dashboard.ex` — `mount/3` assigned
`:greeting_key` via `pick_greeting(scope)` unconditionally. Phoenix
LiveView calls `mount/3` twice for a router-mounted page: once for the
disconnected HTTP render, once for the connected websocket takeover. Each
call independently ran `Enum.random/1` over a ~13-key pool (6 generic keys
plus a tripled time-of-day bucket), so the two passes agreed only by chance
(~1-in-13). In practice the welcome card's text visibly changed a moment
after the page finished loading, on nearly every visit — the exact "mount
runs twice" hazard the `elixir:phoenix-thinking` skill's Iron Law warns
about, and a direct contradiction of the feature's own stated intent (the
moduledoc: *"One KEY is drawn per mount... the visitor gets a different
phrase each page load"* — singular, not two different phrases twenty
milliseconds apart).

**Fix applied:** gated the random draw behind `connected?(socket)` — the
same pattern already used elsewhere in this codebase for connection-only
work (`notifications_bell.ex`, `login.ex`, `registration.ex`,
`magic_link.ex`, `users/auth.ex`). The disconnected pass now assigns the
plain `:welcome_back` default; only the connected pass draws from the pool,
so the visible text is set once and never changes underneath the visitor.

```elixir
defp greeting_key_for_mount(socket) do
  if connected?(socket) do
    pick_greeting(socket.assigns[:phoenix_kit_current_scope])
  else
    :welcome_back
  end
end
```

**Test added:** `test/phoenix_kit_web/live/dashboard_greeting_test.exs` —
pins that a disconnected mount never draws randomly (20 iterations,
DB-free, mirrors `DashboardModuleRefreshTest`'s hand-built `%Socket{}`
pattern), plus a test that an unrecognized greeting key still renders via
the `greeting_text/1` catch-all instead of crashing (guards the "stale
session after a deploy" case the code comment already calls out).

Deliberately **not** tested here: the connected-mount draw itself. That
path also runs `Overview.assign_overview/3`'s presence tracking, which
needs the host app's `PhoenixKit.Admin.Presence` process — not available in
a bare unit-test socket, which is why `DashboardModuleRefreshTest` never
builds a connected socket either. `pick_greeting/1`'s own logic
(time-of-day bucketing, `greeting_text/1` coverage) was checked by hand
against `time_greetings/1`'s clauses — every key it can produce has a
matching `greeting_text/1` clause, so no gap there.

### Verified correct — no action needed

- **`Routes.locale_switch_path/3`** (`lib/phoenix_kit/utils/routes.ex`):
  replaces three previously-drifted copies (`AdminNav.build_locale_url/2`,
  `LayoutWrapper.build_locale_url/2`, `UserDashboardNav`'s inline
  `remove_locale_from_path/1`). Two of the old copies matched against
  *enabled* locale codes while the switcher dropdown was populated from the
  strictly larger *display* set — a language offered but not "enabled"
  round-tripped into a stacked `/en/ja/...` path. The third matched by
  segment shape (2 chars, or 5 with a dash), which both under- and
  over-matched. The new `switchable_locale_codes/1` builds its strip-set
  from exactly what the switcher can emit (display ∪ enabled ∪
  `current_locale`, base codes included), closing the gap. Confirmed no
  dangling callers of the removed `build_locale_url/2` /
  `generate_language_switch_url/2` functions anywhere in the tree (both
  were `def`, not `defp`, so this was checked repo-wide, not just within
  each file) — the removal is clean. All three call sites
  (`admin_nav.ex`, `user_dashboard_nav.ex`) migrated to the new helper with
  `current_locale: assigns[:current_locale]` threaded through; the new
  test file `test/phoenix_kit/utils/locale_switch_path_test.exs` exercises
  the reported repro sequence plus repeated-switching, non-locale
  first-segments, and the `nil`/empty-path edge cases.
- **Leaf 0.6.0 pin** (`mix.exs`, `mix.lock`, `priv/static/assets/phoenix_kit.js`):
  version requirement widened to include `~> 0.6`, lock and CDN pin both
  bumped to `0.6.0` together. `test/phoenix_kit_web/leaf_bundle_pin_test.exs`
  now holds the JS-bundle pin and the Hex lock in sync going forward —
  exactly the kind of drift this PR was fixing for the language switcher,
  guarded proactively here instead of reactively.
- **`welcome_name/1`'s new username fallback** (`dashboard.ex`): the
  `PhoenixKit.Users.Auth.User` schema does carry a `:username` field, so
  `user_username/1`'s pattern match is sound.

## Files changed post-review

- `lib/phoenix_kit_web/live/dashboard.ex` — greeting draw gated on
  `connected?/1`.
- `test/phoenix_kit_web/live/dashboard_greeting_test.exs` — new, pins the
  fix.
