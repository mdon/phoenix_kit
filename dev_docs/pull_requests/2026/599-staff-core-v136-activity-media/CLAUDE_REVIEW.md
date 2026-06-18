# PR #599 — Staff-support core: V136 employment table, Activity `resource_uuid` filter, MediaSelectorModal hardening

**Author:** mdon (Max Don) · **Base:** `main` · **State:** MERGED (`fda2bba8`)
**Reviewer:** Claude · **Date:** 2026-06-17

Three independent strands plus a rider commit. The Activity filter fix and the
`assign_embedded_current_user/2` helper are both clean and well-tested; V136 is
structurally sound and was exercised by the downstream staff suite. Main issue
is release hygiene — a migration + new public API shipped with no version bump
or CHANGELOG entry.

---

## Resolution — addressed in commit `850d27ef` (v1.7.159)

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | Migration + public API shipped unversioned | **Fixed** — `@version` → 1.7.159 + CHANGELOG entry |
| 2 | Upload `accept` desyncs from the in-modal type dropdown | **Fixed** — server-side type gate in `handle_progress` |
| 3 | Browse `where` drops NULL `status` / `system_managed` rows | **Verified non-issue** — `system_managed` is `NOT NULL DEFAULT false` (v113) |
| 4 | `.svg` / `.ogg` in the accept lists | **Kept** — legitimate image/video formats; SVG-XSS is a serve-time concern (storage TODO) |
| 5 | Accepted-types hint hidden in upload-only mode | **Fixed** — hint now always shown |
| 6 | Per-render warning log for an unresolved uuid | **Kept** — useful diagnostic, not noise in practice |

**Finding 2 fix:** the client `accept` list is fixed at `allow_upload` time and
can't track the in-modal dropdown, so `handle_progress` now re-derives the
uploaded file's type (`entry.client_type` / MIME) and rejects a mismatch
(`cancel_upload` + flash) before storing — enforcing the type regardless of how
`accept` was set, and covering any client bypass.

---

## IMPROVEMENT - HIGH

### 1. A schema migration + new public API shipped with no version bump and no CHANGELOG entry

`main` is at `@version "1.7.158"`, and the top CHANGELOG entry for 1.7.158
describes **only** the MDEx centralization from PR #597. PR #599 merged *after*
#597 (`fda2bba8` is HEAD) and adds:

- **V136** — a schema migration that bumps `@current_version` → 136
  (`phoenix_kit_staff_employments`, with a data backfill).
- **`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`** — new public API.
- The **Activity `resource_uuid`** filter behavior change.

None of these is in the CHANGELOG, and there's no version bump. Downstream apps
key off the version to know when to run `mix phoenix_kit.update` / migrations —
a migration landing at the *same* version as an already-described release is a
release-correctness hazard (a consumer on 1.7.158 has no signal that the schema
moved).

**Suggest:** bump to 1.7.159 and add a CHANGELOG entry covering V136 (employment
history table), the Activity `resource_uuid` filter, the MediaSelectorModal
hardening (accept-by-type, `browse: false`, trashed/system-managed exclusion,
per-instance dialog id), and `assign_embedded_current_user/2`. Per project
convention the entry is written against the bumped `@version`.

---

## IMPROVEMENT - MEDIUM

### 2. MediaSelectorModal upload `accept` desyncs from the in-modal type dropdown

`accept_for/1` is applied once, in `maybe_allow_upload/2`, which no-ops after the
upload is allowed (`socket.assigns[:uploads] -> socket`,
`media_selector_modal.ex:163`). `handle_event("filter_type", ...)`
(`media_selector_modal.ex:290`) changes `file_type_filter` and reloads the
browse list but **never re-runs `allow_upload`**.

So when the picker opens with the default `:all` (→ `accept: :any`) and the user
then selects "Images Only" from the dropdown, the browse grid and the copy
switch to images while uploads still accept *any* file — partially defeating the
stated goal ("the picker no longer accepts/stores off-type files"). The
type constraint is only enforced when the **host** fixes `file_type_filter` at
open time (the staff consumer presumably does). There is also no server-side
type guard in `handle_progress/3` — client `accept` is the only gate.

- `lib/phoenix_kit_web/live/components/media_selector_modal.ex:161,290`

**Options:** re-allow on filter change (`cancel_upload` any in-flight entries +
re-`allow_upload`), validate the uploaded type against `file_type_filter`
server-side in `handle_progress/3`, or document that the in-modal dropdown
re-scopes the *library* only, not uploads.

---

## NITPICK

### 3. Browse filter silently drops rows with NULL `status`/`system_managed`

`where([f], f.status != "trashed" and f.system_managed == false)`
(`media_selector_modal.ex:~482`) compiles to SQL where a row with `status IS
NULL` or `system_managed IS NULL` evaluates to NULL → excluded. Schema defaults
are `"processing"` / `false` (`file.ex:137,145`), so newly-created rows are
fine, but any legacy row carrying a NULL in either column would vanish from the
picker. If those DB columns aren't `NOT NULL`, prefer an explicit null-tolerant
predicate (e.g. `f.status != "trashed" or is_nil(f.status)`) or guarantee the
NOT NULL constraint. Low risk.

### 4. `accept_for(:image)` includes `.svg`; `accept_for(:video)` includes `.ogg`

SVG is an XSS vector if ever served inline (the storage signed-URL hardening
TODO already flags this area) — worth excluding from the *image* upload
allow-list. `.ogg` is ambiguous (commonly Ogg **audio**); `.ogv` is the video
container. Both are cosmetic/permissive, not blocking.
(`media_selector_modal.ex:287-288`)

### 5. `browse: false` hides the accepted-types hint — the one mode where it helps most

In a pure uploader the user has no library context, so "Images / Videos /
documents" is exactly the affordance they'd want; the `<p :if={@browse}>` guard
suppresses it (`media_selector_modal.html.heex:~122`). Minor UX; defensible if
the host supplies its own copy.

### 6. `assign_embedded_current_user/2` logs a warning on every unresolved render

A stale/deleted `current_user_uuid` logs a warning on each embedded LV mount
(`auth.ex:860`). For a lingering session this is per-mount log noise. Acceptable
— flagging for awareness. The rescue list is correct given `get_user/1` guards
UUID validity (`UUIDUtils.valid?`), so there's no `Ecto.Query.CastError` path to
catch.

---

## Architectural note (not a finding)

V136 — like V135/V131/V128 before it — creates a `phoenix_kit_staff_*` table and
runs its backfill in **core's** migration chain, so every PhoenixKit install
gets the staff employment table whether or not it uses the staff module. That
coupling is pre-existing (not introduced here), but this PR extends it; worth a
mention if/when the migration system grows per-module gating.

---

## Positive notes / verified

- **V136 is structurally sound.** Verified the FK targets
  (`phoenix_kit_staff_people` v100, `_departments`/`_teams` v100/v101) and the
  `translations` column (v122) all exist before V136, so the `REFERENCES` and
  backfill columns resolve on a full chain. `up/down(opts)` match the dynamic
  `Module.concat([__MODULE__, "V136"]) |> apply(direction, [opts])` dispatch
  (`postgres.ex:1470`); `@current_version` bumped to 136; idempotent (`CREATE …
  IF NOT EXISTS` + `NOT EXISTS` backfill guard); version comment set to
  `'136'`/`'135'` on up/down. The `translations` job_title extraction is
  null-safe (`translations` is `NOT NULL DEFAULT '{}'`). Reportedly green
  against the downstream staff suite (504 tests).
- **Activity `resource_uuid` filter** is a genuine fix: per-resource feeds
  previously leaked every same-type resource's events. `maybe_filter_resource_uuid/2`
  mirrors the sibling filters, the regression test is focused, and the Index LV
  correctly preserves the URL-driven scope across filter changes
  (`activity/index.ex:218`, with a clear comment on why there's no form input).
- **`assign_embedded_current_user/2`** is well-designed and well-tested: no-clobber
  on a router mount, anonymous degradation for absent/unknown/inactive uuid,
  DB-error rescue, and an explicit "identity, not authorization" security note.
- Per-instance `<dialog>` id and the trashed/system-managed exclusion are the
  right hardening for multi-instance pickers.
