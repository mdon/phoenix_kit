# PR #602: Fix notification click-through links (destinations + prefix/locale)

**Author**: @alexdont
**Reviewer**: @CLAUDE
**Status**: ✅ Merged (post-merge review + fixes)
**Commit**: `34239769` (merge), reviewed against `a4b01e5c`
**Date**: 2026-06-22

## Goal

Notification click-through links were broken in two ways:

1. `Render.link_for/1` mapped **every** `"user." <> _` action to `/dashboard/settings`
   (wrongly catching `user.followed`, a connections action) and everything else to
   `nil`, so social notifications (`post.*`, `comment.*`) navigated nowhere and
   follow notifications opened the settings page.
2. Links were built inside the sticky `NotificationsBell` process, which has no
   locale of its own, so click-through used the **default** locale instead of the
   recipient's.

The PR replaces the broad prefix match with an explicit `@account_actions`
whitelist, and threads the recipient's locale (`current_locale_base`) from
`LayoutWrapper` → bell session → `Render.render/2` → `Routes.path(..., locale:)`.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/notifications/render.ex` | `render/2` accepts a locale; `link_for/2` whitelist replaces `"user." <> _` catch-all |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Bell session now carries `"locale" => current_locale_base` |
| `lib/phoenix_kit_web/live/notifications_bell.ex` | Stores `:locale` from session, passes it at click time |
| `test/phoenix_kit/notifications/render_test.exs` | New: link/locale/whitelist coverage |
| `CHANGELOG.md`, `mix.exs` | 1.7.163 |

## Assessment

The core design is sound. Threading an explicit locale from the parent layout is
the right call — the sticky nested bell can't rely on its own process Gettext
locale. The whitelist correctly fixes the `user.followed` mis-routing, and the
dropdown render (`notifications_bell.ex:130`) only consumes `icon`/`text`, so
rendering it without a locale there is harmless (navigation goes through the
`open_notification` handler at line 50, which does pass the locale). The new test
file is well-targeted.

Two real issues found, both fixed; one limitation documented.

## Findings

### BUG - MEDIUM — `user.email_unconfirmed` dropped from the account whitelist

`@account_actions` lists 10 actions; the canonical "account" notification type in
`PhoenixKit.Notifications.Types` (`types.ex:84-104`) lists **11** — the extra one
is `user.email_unconfirmed`. The two lists differ by exactly this action.

`user.email_unconfirmed` is emitted from `live/users/users.ex:692`
(`toggle_user_confirmation_safely/2`) with `actor_uuid: admin.uuid` and
`target_uuid: updated_user.uuid` (target ≠ actor), so it **does** create a
notification for the user. It is the toggle-sibling of `user.email_confirmed`,
emitted from the same code path.

Under the old `"user." <> _` catch-all it received a `/dashboard/settings` link;
the new whitelist omits it, so its notification now has **no click-through link** —
a regression for that one action, and an inconsistency with its confirmed sibling.

**Fix:** added `user.email_unconfirmed` to `@account_actions` in `render.ex` (and
to the test's mirror list, so the whitelist test covers it).

### IMPROVEMENT - MEDIUM — `user.email_unconfirmed` had no `icon_and_text` clause

Pre-existing gap, surfaced while reviewing the area: `user.email_unconfirmed` fell
through to the generic `{"hero-bell", humanize(action)}` → "User email
unconfirmed", while `user.email_confirmed` gets `{"hero-check-badge", "Your email
was confirmed."}`. Inconsistent for two halves of the same toggle.

**Fix:** added `icon_and_text("user.email_unconfirmed", _)` →
`{"hero-exclamation-circle", "Your email is no longer confirmed."}`, plus a test
asserting the dedicated (non-generic) icon/text.

### IMPROVEMENT - MEDIUM (documented, not fixed) — stale locale in the sticky bell

The bell is `sticky: true` with a stable id, so its session (including `"locale"`)
is read **only at initial mount**. Per the codebase's own note in
`utils/routes.ex:130-134`, admin locale switches stay on the WebSocket via
`push_navigate` (no full-page reload), which does **not** re-mount a sticky nested
LiveView. So after an in-session locale switch, the bell's `:locale` assign goes
stale and a subsequent click-through carries the locale from first mount.

Impact is narrow: the destination LV re-resolves its own locale on mount, so the
only artifact is a wrong locale **prefix** in the pushed URL, and only in the
window between an in-session locale switch and the next full reload.

Not fixed, deliberately. There is no per-user language field
(`grep` for `field :.*lang` on the user schema → none), so no stable per-user
locale to resolve from at click time. The robust alternatives each add fragile
machinery or remove the sticky behavior the bell needs to keep its PubSub
subscription across navigation:

- making the bell non-sticky → re-mounts (and flickers / re-subscribes) on every nav;
- `send/2`-ing the new locale to the bell pid on each parent navigation → the
  layout doesn't track the bell pid.

The PR is a strict improvement over "always default locale"; this residual edge
case is logged here so the capability isn't over-trusted. Revisit if/when a
per-user locale preference lands.

## Testing

- [x] Unit tests added/updated (`render_test.exs` — whitelist now includes
      `user.email_unconfirmed`; added icon/text assertion)
- [x] `mix precommit` (format + compile + credo --strict + dialyzer)
- [ ] Stale-locale edge case — documented, not addressed

## Related

- Types source of truth: `lib/phoenix_kit/notifications/types.ex` (account type)
- Emission: `lib/phoenix_kit_web/live/users/users.ex:684-703`
- Locale path building: `lib/phoenix_kit/utils/routes.ex`
