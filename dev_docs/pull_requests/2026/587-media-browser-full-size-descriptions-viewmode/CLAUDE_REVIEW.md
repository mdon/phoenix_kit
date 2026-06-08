# PR #587 — Media browser: full-size page, folder descriptions, view-mode flash fix

**Author:** alexdont · **State:** MERGED (2026-06-08) · **Base:** main
**Reviewer:** Claude

Reviewed post-merge at the user's request. Net assessment: solid, well-scoped
work. Migration follows the V131 convention exactly, the list-table column math
is correct, the save path is scope-aware with proper error flashes,
`persist_user_view_mode/2` is concurrency-safe (re-reads fresh `custom_fields`
before merge), and there is a real changeset + DB round-trip test. Findings
below are cleanup/polish — nothing blocking.

---

## IMPROVEMENT - MEDIUM — Dead client-side view-mode persistence left behind

The PR moved grid/list preference to server-side per-user storage and removed
the localStorage **read** in `MediaDragDrop.mounted`, but left the localStorage
**write** and its plumbing:

- `priv/static/assets/phoenix_kit.js:3433-3441` — `setupViewModePersistence()`
  still does `localStorage.setItem("phoenix_kit_media_view_mode", mode)` on every
  toggle click. Nothing reads that key anymore (the only reader was deleted), so
  it's a dead write. It also sets `document.documentElement.dataset.mediaView`,
  which has no CSS/JS consumer anywhere in the tree.
- The toggle buttons (`media_browser.html.heex:531,544`) carry `data-view-mode`
  attributes that only `setupViewModePersistence` reads.

The buttons already have `phx-click="set_view_mode"`, which now persists
server-side — so `setupViewModePersistence()`, its call at `phoenix_kit.js:3426`,
and the two `data-view-mode` attrs are entirely dead. Recommend removing them.
Beyond being dead code, the lingering localStorage write is misleading: it
reads as if client persistence is still active, which a future dev could "fix"
back into the flash bug this PR just eliminated.

## IMPROVEMENT - MEDIUM — View-mode preference pollutes the global custom-field registry + broadcasts on every toggle

`persist_user_view_mode/2` saves through `Auth.update_user_custom_fields/2`, which
(`auth.ex:1600`) calls `CustomFields.ensure_definitions_exist/1` and broadcasts
`Events.broadcast_user_updated/1`. The first time any user clicks the grid/list
toggle, `ensure_definitions_exist` (`custom_fields.ex:522`) auto-registers a
**global** field definition `media_view_mode` (label "Media View Mode",
`user_accessible: false`) into the admin Custom Fields registry — an internal UI
preference now shows up alongside real profile fields. Every subsequent toggle
also fires a `user_updated` PubSub broadcast + `Repo.update`, turning a trivial
view switch into cross-process work (any LV subscribed to user-updated re-renders).

**Caveat — this is a pre-existing project pattern, not introduced by this PR:**
`Notifications.Prefs.update` (`notification_preferences`) and `media_canvas_viewer`
(`etcher_colors`, `etcher_line_params`) already persist per-user UI state the same
way and pollute the registry identically. So the PR is *consistent*. The real fix
is project-wide: either have `ensure_definitions_exist` skip non-`user_accessible`
internal keys (a reserved-prefix or allowlist), or route UI-preference writes
through a path that doesn't auto-register definitions. Worth raising with the
maintainer rather than fixing in isolation here.

## IMPROVEMENT - MEDIUM — Description editors re-render on every keystroke

All three inline description editors bind `phx-change="folder_description_input"`
with **no `phx-debounce`**, so each keystroke round-trips to the server and
re-renders the component. The sibling rename input on the same screen uses
`phx-debounce="50"`, so this is both wasteful and inconsistent.

The change handler exists only to keep `@folder_description_text` synced, but the
submit path doesn't need it: the `<textarea>` is focus-preserved by LiveView
across re-renders, and `phx-submit` already carries the typed `description` param.
Either:
- drop `phx-change="folder_description_input"` (+ the handler) and let the
  textarea be uncontrolled until submit, or
- add `phx-debounce="blur"` (or `"300"`) if live-syncing the assign is desired.

Files: `media_browser.html.heex` (header editor ~L363, grid editor ~L495, list
editor ~L777) and the `folder_description_input` handler in `media_browser.ex`.

## NITPICK — Header description editor missing Escape-to-cancel

The grid and list inline editors bind
`phx-keydown="cancel_edit_folder_description" phx-key="Escape"` on the textarea;
the current-folder **header** editor (`media_browser.html.heex` ~L369) does not.
Add it for parity — users will expect Esc to close all three.

## NITPICK — Avoidable DB read when seeding the editor

`start_edit_folder_description` calls `Storage.get_folder(folder_uuid)` purely to
seed `@folder_description_text`, but the folder struct (with `description`) is
already loaded in `@folders` / `@current_folder`. Seeding from the in-memory list
avoids the query. The re-fetch in `save_folder_description` is defensible (fresh
row before write); the seed fetch is not.

## NITPICK — `load_user_view_mode(%{} = user)` assumes a `%User{}`

`Auth.get_user_field/2` only has `%User{}` clauses, so a non-`User` map reaching
`phoenix_kit_current_user` would raise `FunctionClauseError` during `update/3`.
In practice the assign is always a `%User{}` or `nil`, so risk is low — but
matching `%User{}` in the head (falling through to the existing `_` clause for
anything else) would make it robust. Optional.

## NITPICK — `h-[calc(100dvh-4rem)]` hardcodes header height

`media.html.heex` pins the page height to `100dvh - 4rem`, assuming a 4rem
layout header. If a host app's header height differs, the grid will clip or leave
a gap. Acceptable given the admin layout is PhoenixKit-owned, but it's a magic
number worth a comment.

---

## Verified good

- **V132 migration** mirrors V131 exactly: `ADD COLUMN IF NOT EXISTS`, idempotent,
  correct `COMMENT ON TABLE … IS '132'` marker, `@current_version` bumped 131→132.
- **List-table column math** is correct: new `Description` `<th>`, `colspan="6"`
  on the rename/description edit rows, and a `—` placeholder cell added to file
  rows so every row stays aligned.
- **Save path** uses `Folder.changeset` (casts + 2000-char validates the new
  field), is scope-aware, and flashes distinct messages for `:out_of_scope` vs
  generic errors. Blank/whitespace clears to `nil`.
- **`persist_user_view_mode/2`** re-reads the user before merging `custom_fields`,
  avoiding clobbering a concurrent change, and degrades to a no-op for the
  no-user / error cases.
- **Test** covers changeset cast, over-length rejection, optionality, and a real
  persist→clear DB round-trip.
- The bundled `leaf 0.2.21→0.2.22` bump (1.7.137) is out of the stated scope but
  documented in the CHANGELOG and harmless.
