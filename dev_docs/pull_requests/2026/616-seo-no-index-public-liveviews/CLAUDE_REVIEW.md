# PR #616 — Honor seo_no_index on host-app public LiveViews

**Author:** timujinne (`fix/seo-no-index-public-liveviews`) · **Merge:** `099b75ec` · **Reviewer:** Claude

## Summary

One file, +9 lines, plus a new regression test. `root.html.heex` renders the
`noindex,nofollow` meta tags from `assigns[:seo_no_index]`, but the only place
that assign was being set was `LayoutWrapper.app_layout_inner/1` — which wraps
PhoenixKit's own admin/plugin views, never a host app's own public LiveViews
(their own layout, mounted only through PhoenixKit's `on_mount` chain for
`current_user`/locale support). Those pages never got the assign, so the SEO
module's `noindex` directive silently didn't apply to them.

Fix: `set_routing_info/3` — the `:handle_params` hook attached by
`mount_phoenix_kit_current_user/2` (itself reached via every
`:phoenix_kit_mount_current_scope`/`:phoenix_kit_mount_current_user`/etc.
`on_mount` clause) — now also does
`assign_new(:seo_no_index, fn -> SEO.no_index_enabled?() end)`.

**Verdict: correct, safe to release.** No findings.

## Verification

- Confirmed the hook wiring end-to-end: `on_mount(:phoenix_kit_mount_current_scope, ...)`
  calls `mount_phoenix_kit_current_scope/3`, which calls
  `mount_phoenix_kit_current_user/2`, which `attach_hook(socket, :current_page,
  :handle_params, &set_routing_info/3)`. So the new `assign_new` runs on
  `handle_params` — before first render, and on every subsequent navigation —
  for any LiveView using any of PhoenixKit's `on_mount` variants, not just
  admin/plugin views. Matches the PR's claim. ✓
- `assign_new/3` is correctly a no-op if the assign is already present, so for
  admin/plugin views where `LayoutWrapper.app_layout_inner/1` also sets
  `:seo_no_index` there's no conflict or double-computation of note — whichever
  runs first wins, and both compute the same value from the same source
  (`SEO.no_index_enabled?/0`). ✓
- `SEO.no_index_enabled?/0` is a `Settings.get_boolean_setting/2` read — this
  runs in `handle_params`, not `mount/3`, so it's consistent with the Iron Law
  (queries belong in `handle_params`, once per navigation, not in `mount`). ✓
- `root.html.heex`'s `<%= if assigns[:seo_no_index] do %>` block (pre-existing,
  untouched by this PR) is what actually consumes the assign — confirmed it
  reads the same key this PR now guarantees is set. ✓
- New test (`auth_seo_no_index_test.exs`) exercises a `PublicHostAppLive` stand-in
  that mounts via `on_mount {PhoenixKitWeb.Users.Auth,
  :phoenix_kit_mount_current_scope}` and asserts `assigns[:seo_no_index]` reaches
  the rendered HTML for both the enabled and disabled cases. Note this uses
  `live_isolated/3`, which doesn't render `root.html.heex` — so it verifies the
  on_mount→assign propagation (the actual bug) but not the full root-layout
  render path; that gap is pre-existing/inherent to `live_isolated` and not
  something this PR introduced or could reasonably close in a unit test. ✓

## Gate

Covered by the combined `mix precommit` run for this release batch (PRs
#613–#616); result recorded in the release commit/notes.
