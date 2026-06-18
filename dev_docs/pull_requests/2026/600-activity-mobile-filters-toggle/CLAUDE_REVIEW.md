# PR #600 — Activity page: one-row mobile filters, grid/list toggle, mobile list

**Author:** alexdont (Sasha Don) · **Base:** `main` · **State:** MERGED (`9a8d95b0`)
**Reviewer:** Claude · **Date:** 2026-06-17

A follow-up to the admin-UI pass (#597): the Activity filter toolbar becomes
compact media-style dropdowns (patch links via `filter_path/2`), a persisted
grid/list toggle, a mobile-friendly list, and a user-form button reorder.

**Verdict: Approved** — the UI work is clean and the dropdown options are patch
links (no `String.to_atom`/`to_existing_atom` on user input, so no atom-table
risk). Two regressions of fixes that landed in 1.7.159 needed correcting; both
are fixed below.

---

## Resolution — addressed in this branch (rolls into the unreleased v1.7.159)

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | View-mode toggle reintroduces the broadcast + custom-field-definition leak | **Fixed** |
| 2 | `filter_path/2` drops the `resource_uuid` deep-link scope | **Fixed** |
| 3 | `load_user_view_mode(%{})` over-broad match | **Fixed** — `%User{}` |
| 4 | Dead `handle_event("filter", …)` clause | **Kept** (noted below) |

---

## BUG - MEDIUM

### 1. Activity view-mode toggle reintroduces the broadcast + custom-field-definition leak (regression of 1.7.159)

`persist_user_view_mode/2` (`activity/index.ex`) called
`Auth.update_user_custom_fields(fresh, merged)` — the 2-arity form — which is
exactly the buggy pattern fixed for the users table in 1.7.159. Consequences:

- It registers `activity_view_mode` as a user-facing custom-field definition
  (via `CustomFields.ensure_definitions_exist/1`), which then surfaces in the
  **Customize Columns** modal (`get_custom_field_columns/0` lists every enabled
  definition with no internal-key exclusion).
- It broadcasts `user_updated`. The Activity LV doesn't subscribe to user
  events, but every admin on `/admin/users` does — so toggling the activity
  grid/list silently re-queries the users list for all of them.

**Fix:** pass `ensure_definitions: false, broadcast: false` (the opts added to
`update_user_custom_fields/3` in 1.7.159), mirroring the users-table fix.

### 2. Filter dropdowns drop the `resource_uuid` deep-link scope (regression of #599)

`filter_path/2` built the query from `module` / `mode` / `action` /
`resource_type` only — not `resource_uuid`. The Activity page supports a
`?resource_uuid=…` per-resource feed (added in #599 / 1.7.159). Because the new
toolbar options are patch links built by `filter_path/2`, picking any filter
while on a resource-scoped feed dropped the scope and reverted to **all**
activity — the exact "per-resource feed leaks all events" bug #599 fixed,
reintroduced through the toolbar. (The old `handle_event("filter", …)` clause
preserved it via `maybe_put`, but the selects are no longer wired to it.)

**Fix:** include `"resource_uuid" => assigns[:filter_resource_uuid]` in the
`filter_path/2` base map.

---

## NITPICK

### 3. `load_user_view_mode(%{})` matches any map

Same as the users table: `%{}` matches any map then calls
`Auth.get_user_field(%User{} = user, …)`. `phoenix_kit_current_user` is always a
`%User{}` or `nil` (covered by the `_` clause), so it's safe in practice — but a
non-`User` map would raise instead of falling through to `"table"`. Tightened to
`%User{}` (added the `alias`).

### 4. Dead `handle_event("filter", …)` clause

Replacing the `<.form phx-change="filter">` selects with patch links leaves the
`handle_event("filter", …)` clause with no caller. Left in place — it's
harmless, and removing it is out of scope for this review. Worth a cleanup pass
later (or repurpose it; it was the thing that used to preserve `resource_uuid`).

### 5. User-form buttons remain untranslated

`Cancel` / `Create User` / `Update User` are plain literals — but they were
already plain before this PR (it only reorders them), so not introduced here.
Fold into a future i18n sweep.

---

## Positive notes

- Filter options are `<.link patch={…}>` built server-side from a whitelist of
  known values — no `String.to_atom`/`to_existing_atom` on request data.
- `set_view_mode` is guarded `when mode in ["card", "table"]`.
- The mobile responsive approach (`table-fixed md:table-auto`, `hidden
  md:table-cell`, actor folded into a `md:hidden` sub-line) mirrors the users
  table and the media list — consistent with the established pattern.
