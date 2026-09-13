# PR #805 — Fix raw permission-error atom leaking into role-editor flash

**Author:** timujinne (`a031/flash-atom-to-text`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Correct and complete. No changes needed.

## Summary of the PR

- `Roles` (`show_permissions_editor`) handed the bare `{:error, atom}` reason
  from `Permissions.can_edit_role_permissions?/2` straight to `put_flash`, so a
  blocked click showed `owner_immutable`.
- The private `permission_error_message/1` in `PermissionsMatrix` moved to
  `Permissions.edit_role_permissions_error_message/1`, and both LiveViews call it.

## Verified

- **Every caller that flashes the reason is covered.** `rg can_edit_role_permissions?`
  finds four call sites. Two flash the reason (`roles.ex:254`,
  `permissions_matrix.ex:79`), and both now translate it. The other two only
  compare `!= :ok`.
- **The clause set mirrors the producer.** `can_edit_role_permissions?/2` returns
  `:not_authenticated | :owner_immutable | :self_role | :admin_owner_only`, and
  each one has a clause plus a catch-all.
- **Gettext.** The msgids are unchanged, so the move only drifts `#:`
  references. The `extract` + `merge` in this release reported no rewording.

## NITPICK — domain context now depends on the web Gettext backend

`PhoenixKit.Users.Permissions` gains `use Gettext, backend: PhoenixKitWeb.Gettext`.
That is the established pattern (23 `lib/phoenix_kit` modules already do it),
so it is not worth splitting out.
