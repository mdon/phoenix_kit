# PR #605: Notifications graceful handling + user/file comment-resource links

**Author**: @alexdont (Sasha Don)
**Reviewer**: @CLAUDE
**Status**: ✅ Merged (post-merge review + fixes)
**Commit**: `aaea9a6e` (merge), reviewed as the net diff `a9bc2dda..aaea9a6e`
**Date**: 2026-06-24

## Goal

Three things:

1. **Notifications — graceful no-link handling.** A notification with no
   click-through link should read as informational (default cursor) rather than
   broken; clicking it still clears its unread state. Adds a
   `notification_default_link` catch-all setting (defaults to `/dashboard`,
   guarded to no-op when the user dashboard is disabled) and an opt-in dev nudge
   (`config :phoenix_kit, warn_unlinked_notifications: true`).
2. **Comments — `user` resource handler.** `PhoenixKit.Users.CommentResources`
   resolves a comment attached to a user (`resource_type: "user"`) to the user's
   display name + `/admin/users/view/:uuid` + avatar thumbnail.
3. **Comments — double-prefix fix.** Comment-resource handlers must return a
   **raw** path (the comments module applies `Routes.path/1` once); the `file`
   handler pre-applied it, double-prefixing under a non-root `url_prefix`. `file`
   and the new `user` handler now both return raw paths, matching `post`.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/users/comment_resources.ex` | **New** `user` comment-resource handler (single `WHERE uuid IN` query, avatar precedence, raw path) |
| `lib/phoenix_kit/annotations/annotations.ex` | `file` handler returns raw `/admin/media/:uuid` (drops the pre-applied `Routes.path/1`) |
| `lib/phoenix_kit_web/live/notifications_bell.ex` | Effective target = own link ∥ `default_link`; cursor reflects navigability; `default_link/1` from the new setting; dev `warn_unlinked/1` |
| `lib/phoenix_kit_web/live/settings.html.heex` | New `notification_default_link` input |
| `test/phoenix_kit/users/comment_resources_test.exs` | **New** tests for the `user` handler |
| `skills-lock.json` | **New** (accidental — see findings) |

## Assessment

Solid, well-reasoned PR. I verified the load-bearing facts against core:

- **The double-prefix fix is correct.** The very existence of an observed
  double-prefix proves the comments module *does* apply `Routes.path/1` to the
  returned path — so returning a raw path is right, and it aligns `file` + the
  new `user` handler with the pre-existing `post` convention. ✅
- **`CommentResources` is sound.** `User.full_name/1` always matches a `%User{}`
  (org-name clause + a catch-all first/last clause that handles all-nil), so
  `display_name/1` never raises and falls back to email cleanly. `custom_fields`
  is a schema field defaulting to `%{}`, so the avatar pattern matches degrade to
  `nil` safely. `URLSigner.signed_url/2` arity is correct. The lookup is a single
  `WHERE uuid IN (...)` — **no N+1**. The broad `rescue _ -> %{}` mirrors the
  existing `file` handler exactly (annotations.ex), so it's the established
  fail-soft convention for resource resolvers, not a new smell. ✅
- **The new setting persists and "clear to disable" works.** `update_settings/1`
  iterates `changeset.params` (raw params), so `notification_default_link` saves
  even though it isn't a `SettingsForm` field. It is **not** in `get_defaults/0`,
  so clearing the field stores `""` (not a reverted default) and `default_link/1`
  maps `"" -> nil` → non-navigating, exactly as documented. ✅
- **`Config.user_dashboard_enabled?/0` exists** (`config/config.ex`), so the
  `/dashboard` guard compiles and does what the comment claims. ✅
- **Locale threading is consistent** with PR #602: `Render.render(n, @locale)`
  and `Routes.path(path, locale: locale)`. ✅

Two improvements applied, one cleanup applied, a few notes below.

## Findings

### IMPROVEMENT - MEDIUM (fixed) — `default_link/1` did an uncached settings query on a hot path

`refresh/1` runs in `mount/3` (which fires twice — dead + connected render) and
on **every** notification PubSub event (`notification_created`, `_seen`,
`_dismissed`, bulk). #605 added `default_link/1` to `refresh/1`, and it called
`Settings.get_setting/2` — the **uncached** variant
(`get_setting/2 → get_setting/1 → Queries.get_setting_by_key/1`, a direct DB
hit). So the sticky bell, present on every authenticated page for every user,
issued an extra settings query per render and per notification event.

**Fix:** switched to `Settings.get_setting_cached/2` (ETS-backed, with a built-in
DB fallback if the cache is unavailable). The settings cache is invalidated on
save (`update_settings/1` → `Cache.invalidate_multiple/2`), so the bell still
picks up an admin change on the next refresh. Strictly better, same semantics.

### IMPROVEMENT - LOW (fixed) — `skills-lock.json` committed at repo root

`skills-lock.json` (a Claude Code *skills* lockfile pinning the `daisyui` skill)
was committed at the repo root. The repo already gitignores `/.claude` (and
`.mcp.json`), so the team's convention is to keep Claude tooling artifacts out of
version control; this file escaped only because it lives at the root, not under
`.claude/`. It also contradicts the PR's own "code only" note. It does **not**
ship to Hex (the `mix.exs` `files:` whitelist is `lib priv mix.exs README.md
LICENSE CHANGELOG.md`), so this is repo hygiene, not a release problem.

**Fix:** removed `skills-lock.json` from tracking and added `/skills-lock.json`
to `.gitignore`. *If the team actually wants to pin skills in-repo (lockfile
style), revert this one change — but that would also argue for un-ignoring
`/.claude`.*

### NITPICK — admin-set default link is not constrained to same-origin

`default_link/1` accepts any `"/" <> _` value, so an admin who sets
`notification_default_link` to `//evil.com` would get a protocol-relative target
passed to `push_navigate`. The value is **admin-configured** (not end-user
input), so this is self-inflicted and low-risk, but a `String.starts_with?(path,
"//")` reject (or requiring a single leading slash) would close it. Not changed.

### NITPICK — raw `<input>` in settings form instead of core `<.input>`

The new field uses a raw `<input>` rather than `PhoenixKitWeb.Components.Core.Input`
(CLAUDE.md prefers the core component in new code). It matches the surrounding
settings-form style (the whole section uses raw inputs), so left as-is for
consistency; worth folding into a future settings-form component sweep.

### OBSERVATION (pre-existing, not fixed) — queries in `mount/3`

`refresh/1` runs in `mount/3`, which is called twice; it does `count_unread` +
`recent_for_user` (+ the now-cached `default_link`). This predates #605 (the bell
is a sticky nested LV that wants its count on first paint and doesn't own
`handle_params`). The cache fix above removes the third query from the hot path;
the two notification reads remain. Noted, not changed — moving them to
`handle_params`/`assign_async` is a larger refactor of the bell's lifecycle.

## Testing

- [x] `mix precommit` (compile --warnings-as-errors + credo --strict + dialyzer)
- [x] Author's suite: comment-resource tests (`comment_resources_test.exs`) +
      notification tests, reported 12/12
- [ ] No unit test added for `default_link/1`'s branch table (empty → nil,
      `/dashboard` guarded, `/path`, else nil) — it's a private fn in a
      DataCase-requiring LiveView; folded into the standing notifications-test gap.

## Related

- Comment-resource convention: `lib/phoenix_kit/annotations/annotations.ex` (`file` handler, mirror for the new `user` handler)
- Settings cache: `lib/phoenix_kit/settings/settings.ex` (`get_setting_cached/2`, `update_settings/1` invalidation)
- Dashboard guard: `lib/phoenix_kit/config/config.ex` (`user_dashboard_enabled?/0`)
- Locale threading precedent: PR #602 review (`render.ex`, sticky-bell locale)
