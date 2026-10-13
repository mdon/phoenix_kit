# PR #928 — Admin "Edit" link in the account menu

**Author:** timujinne · **Merged:** 2026-10-13 (770dec089) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

`admin_edit_url`/`admin_edit_label` (set by `AdminEditHelper.assign_admin_edit/3`) are threaded by `layouts/admin.html.heex`
into `LayoutWrapper.app_layout/1` and on to `admin_user_dropdown`, where the entry renders first. A `module_assigns` pair wins
and moves together (URL never gets the page's label). Host layouts receive the same pair as top-level assigns. Test-only probe
route added in the dev/test block of the router.

Verdict: correct. No bugs found.

## Checked

- The permission gate lives in `assign_admin_edit/3`; the chrome only backstops with `Scope.can_access_admin_area?/1`, and the
  guide says so explicitly for hand-filled `module_assigns`.
- A view calling `app_layout/1` directly cannot see its caller's assigns — documented with the explicit-attr snippet.
- The probe route sits under the existing test-only router block, so it does not ship in a host's routes.
