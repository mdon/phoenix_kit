# PR #595 — MediaBrowser: mobile layout, sidebar branch highlight, folder UX fixes

Reviewed post-merge (2026-06-17). Branch already on `main`. No blocking issues — the PR
is solid and the logic (scope handling, header refresh, active-path walk) holds up. One
real responsive inconsistency and two notes.

## IMPROVEMENT - MEDIUM — list-view mobile meta line double-renders Type/Size on tablets

`lib/phoenix_kit_web/components/media_browser.html.heex`

The folded "mobile meta line" under the name uses `md:hidden`, but the columns it's meant
to replace switch at different breakpoints:

- Type column — `hidden sm:table-cell`
- Size column — `hidden sm:table-cell`
- Date column — `hidden md:table-cell`
- Meta line (`TYPE · SIZE · DATE` for files; `Folder · DATE` for folders) — `md:hidden`

In the `[sm, md)` band (≈640–768px, tablet portrait) the Type and Size **columns are
visible** *and* the meta line is **also visible** — so each row shows the type badge +
size cell **and** a redundant `PNG · 2 MB · Jun 16` line beneath the name.

**Fix:** align the Type/Size columns to the same breakpoint as Date so columns and the
meta line cross over together:

```diff
- <th class="hidden sm:table-cell">{gettext("Type")}</th>
- <th class="hidden sm:table-cell">{gettext("Size")}</th>
+ <th class="hidden md:table-cell">{gettext("Type")}</th>
+ <th class="hidden md:table-cell">{gettext("Size")}</th>
```
…and the matching `<td>`s (folder Type badge + empty Size cell; file Type badge + Size
cell). After this, below `md` only the meta line shows; at/above `md` only the columns.
(Don't instead make the meta line `sm:hidden` — that drops Date entirely in the `[sm, md)`
band, since the Date column only appears at `md`.)

## NITPICK — `search_folders/3` doesn't escape LIKE wildcards

`lib/modules/storage/storage.ex` — `ilike(f.name, ^"%#{search}%")` interpolates the raw
search term into the pattern, so a user-typed `%` or `_` acts as a wildcard. **Not a
regression and not injection** (the value is still parameterized) — `apply_file_search/2`
does exactly the same thing, so the new folder search is consistent with the existing file
search. Flagging only for parity: if wildcard-escaping is ever added, do both sites.

## Note — behavior change is intentional

`submit_new_folder` no longer opens inline rename on the freshly created folder (the old
`create_untitled_folder` did). That's by design per the PR — the name-it modal replaces the
create-then-rename flow. `refresh_header_folder/3` correctly syncs `current_folder`,
`scope_folder`/`scope_folder_name`, and the open header-edit panel after a sidebar rename.

## Verified good

- `active_path_uuids/2` → `find_node_path/2` is an O(n) walk over the already-nested tree;
  empty MapSet when no/absent current folder. Trash view suppresses the highlight via the
  `filter_trash` guard in `on_path_child_index`.
- Connector-class strings are spelled out as whole literal Tailwind classes (JIT-safe), per
  the in-file note.
- Scope branch in `search_folders/3` excludes the scope folder itself from results.
