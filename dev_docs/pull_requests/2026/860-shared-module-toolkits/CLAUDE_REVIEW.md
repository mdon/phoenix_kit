# PR #860 — Shared toolkits for every module (V201)

**Author:** mdon · **Merged:** 2026-09-23 (5444f3bc) · **Reviewer:** Claude · **Released in:** not yet released

## Summary

Five things that modules each copied now live in core, and the modules
will adopt them:

- `Activity.log/3` and `PhoenixKitWeb.Actor`
- `TreePicker`, with `Utils.Tree` and `Utils.TreeQuery`
- per-record media folders (`Storage.ResourceFolders`, plus the
  reorganizer's `ResourceSource`)
- an upload toolkit (`PhoenixKitWeb.Attachments`)
- per-user table columns (`ViewPrefs`, `TableColumns`), stored in the new
  `phoenix_kit_user_view_prefs` table (V201)

Stored files are now served `inline` only for media, PDF and plain text,
always with `nosniff`.

I reviewed it in three areas. I read each one against the CLAUDE.md
landmines, and checked the recursive CTEs against the prefix gotcha.

- **Migration and table columns: clean.**
  - V201 follows every prefix-safe rule and uses `uuid_v7_call`. Its unique
    index matches the upsert's `conflict_target`, and `down/0` is correct.
  - Legacy settings are still read as the site default.
- **Activity, actor, tree picker and UI: clean.**
  - `log/3` really never raises. `Actor` reads the scope's active role.
  - Picks are re-validated on the server, including crafted and disabled
    ones. The JS hook ships through the bundle.
  - Gettext has 0 fuzzy entries and all 7 locales are complete.
- **Storage and serving: one bug and three improvements, below.**
  - `TreeQuery`'s CTEs are prefix-safe: the inner `from` carries
    `@schema_prefix`.
  - The system-managed and delete-through-`delete_stored_objects` rules
    hold.

Verdict: solid, carefully tested work. The fixes below are applied.

## Findings

### BUG - MEDIUM — a trashed-folder retry during rehome raised instead of trying the next folder

`remove_file_from_folder/2` now runs in its own transaction.
`rehome_into_first_live/2` opened a second one inside it: it wrote the new
home, then checked whether the folder was live, and rolled back with
`:folder_trashed` to try the next link. Rolling back a nested transaction
marks the outer one as failed, so the next query in the recursion raised
`DBConnection.ConnectionError`. That query was the next `update`, or
`trash_file/1` when no candidates were left. The media browser calls this
directly, so its LiveView crashed. `ResourceFolders.detach/2` turned the
crash into `{:error, _}`, so removal on that path always failed.

This only happens when a linked folder is trashed between the unlocked
`other_folder_links/2` read and the check.

**Fix:** check each folder first, then write, with no nested transaction.
A write error rolls back the outer transaction. The comment now says the
race is narrowed, not closed: `trash_folder/1`'s file sweep reads the
file's old home, and the old write-then-check order had the same window.
No test, because reproducing it takes two processes timed inside the
window.

### IMPROVEMENT - MEDIUM — `file_trashed` was broadcast before the commit

The same new transaction meant `trash_file/1` broadcast
`{:phoenix_kit_file_trashed, _}` from inside it. A subscriber that reloads
on that message could still read the file as live. The reorganizer's own
comments require announcing after the commit.

**Fix:** the write is split into a private `mark_trashed/1` with no
broadcast. `remove_locked`/`rehome_into_first_live` use it, and
`remove_file_from_folder/2` broadcasts once the transaction has
committed. The public `trash_file/1` is unchanged.

### IMPROVEMENT - MEDIUM — `ResourceFolders.purge_named/1` would delete any folder with that name

The docs say it is for names that embed the record's uuid, but nothing
checked that. It matches across the whole install, so a module passing a
plain host name (`"Invoices"`) would permanently delete every user folder
with that name, along with its files.

**Fix:** a name with no uuid in it is refused: a warning is logged and
nothing is deleted. The existing test now uses a name with a uuid in it,
and a new test covers the refusal.

### IMPROVEMENT - MEDIUM — not fixed: public buckets now proxy every non-inline type through the app

`FileController` used to redirect every public-bucket request. It now
redirects only the inline types. Everything else goes through
`proxy_remote_file/5`: zip, docx and csv as well as HTML and SVG. The file
is downloaded to a temp file and then sent, on every request, with no
range support and no CDN. The security reason covers the types that
render: an HTML or SVG upload would otherwise render on the bucket's
origin. Plain binary downloads gain nothing from the proxy and cost
bandwidth and disk.

**Not changed:** it is a trade-off for the maintainer. The alternatives
are to narrow the proxy to the render-capable types (a denylist, weaker
than today's allowlist), or to redirect to a presigned URL with
`response-content-disposition=attachment` where the adapter supports it.
Hosts that serve large downloads from a public bucket should be told in
the release CHANGELOG.

### IMPROVEMENT - MEDIUM — docs told modules to call new APIs unguarded

AGENTS.md and the activity-feed guide said to call `Activity.log/3` and
`PhoenixKitWeb.Actor` with "no guard". Both are missing in core ≤ 2.37.5,
and modules keep the open `~> 2.0` pin. So a host on an older core that
updates a module would get `UndefinedFunctionError`.

**Fix:** both docs now say to feature-detect
(`function_exported?(PhoenixKit.Activity, :log, 3)` after
`Code.ensure_loaded?/1`) until the module raises its core floor.

### NITPICK — the Users page read column prefs by the bare user, but saved them by the scope

`assign_columns/1` read with `@phoenix_kit_current_user`.
`TableColumns.handle_event/5` and the website-access page use
`Actor.uuid/1`, which reads the scope first. **Fix:** the Users page
reads with `Actor.uuid(socket)` too.

### NITPICK — Spanish used the informal form

The new string `"Sign in to upload files."` used `Inicia sesión`, while its
sibling strings use `Inicie sesión`. **Fix:** changed to the formal form.

### NITPICK — a comment was left above the wrong function

`stored_ext/2` was inserted between `resolve_mime_type/2` and its comment.
**Fix:** the comment is moved back above `resolve_mime_type/2`.

### NITPICK — `default.pot` was out of date

`mix gettext.extract --check-up-to-date` failed on the merged tree. Only
source references had moved (no msgid changes). **Fix:** re-extracted and
merged. Every catalogue still has 0 fuzzy entries, and the only msgstr
change is the Spanish fix above.

## For the release CHANGELOG

- The column settings in the admin UI now save per user. The legacy
  site-wide `user_table_columns` / `website_access_attempt_columns` values
  become a default that no UI can change. To return to the built-in
  default, delete those two settings rows.
- Per-user column choices that modules kept in `custom_fields` are not
  copied into the new table. Each module has to migrate its own when it
  adopts `TableColumns`.
- A database that ran an earlier build of this branch while its migration
  was still numbered V200 has to reset its version marker to 199 (see the
  PR description).
- The public-bucket proxying change described above.

## Not checked here (noted, predates this PR)

`Reorganizer.lock_folder/1` takes `FOR UPDATE` on folder rows that other
tables reference by foreign key. Against a concurrent
`ResourceFolders.ensure(..., claim:)` whose pointer column is a foreign
key to folders, that could form a lock cycle. It is the same pattern as
the 2026-08-12 role-row fix, and `FOR NO KEY UPDATE` would avoid it. Not
reproduced.
