# PR #550 — Updated media browser with fresco new version (Etcher 0.3 / Fresco 0.5)

Reviewed post-merge (merge commit `7c16f333`). Skills: `elixir:phoenix-thinking`, `elixir:ecto-thinking`.

## Summary

Large, well-staged migration to Etcher 0.3 + Fresco 0.5: per-op annotation
events collapse into a single bulk `etcher:annotations-changed` diff; the
canvas + annotations + composer + comments stack is extracted into a shared
`MediaCanvasViewer` LiveComponent embedded by both MediaBrowser and
MediaViewer; the `line` annotation kind is added (V121); the V120 doc-presets
index is guarded for hosts without the Document Creator module.

Commit hygiene is excellent — each commit is self-contained with a thorough
rationale. The single-root regression test is a sharp catch. Backend findings
below; JS bridge code reviewed lightly.

## Resolution status

Fixed in follow-up commit on `dev` (post-merge):

- ✅ V121 constraint guard — DO-block guard removed, `ADD CONSTRAINT` now unconditional after the `DROP IF EXISTS`.
- ✅ `:uuid` castable on update — `Annotations.update/2` now strips `:uuid` from attrs before the changeset.
- ✅ `sync_annotations/3` no-op UPDATE storm — added an `annotation_unchanged?/2` dirty-check (geometry/style/kind) so untouched rows skip their UPDATE. A follow-up `/simplify` pass also guards the post-loop DB reload + canvas rebuild behind a `wrote? or to_delete != []` check, so a re-broadcast with no net change returns the socket untouched.

Left for the developer (need decisions / external-package knowledge):

- ⚠️ Hard-delete of linked comments — needs confirmation of the PhoenixKitComments reply FK before any change. See finding below.
- ⚠️ `creator_uuid` adapter-writable — can't simply exclude it like `file_uuid` (it's set before `filter_to_schema/1`, not after). Low priority; documented below.

## Findings

### BUG - MEDIUM — V121 constraint guard ignores the table prefix/schema — ✅ FIXED

`lib/phoenix_kit/migrations/postgres/v121.ex`:

```sql
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'phoenix_kit_annotations_kind_check'
  ) THEN
    ALTER TABLE #{p}phoenix_kit_annotations ADD CONSTRAINT ...
```

`pg_constraint.conname` is unique per *namespace*, not globally. The query has
no `connamespace` filter. On a multi-prefix install (PhoenixKit supports a
table prefix), running V121 against prefix B: the `DROP CONSTRAINT IF EXISTS`
removes B's constraint, but the `IF NOT EXISTS` check still sees prefix A's
identically-named constraint → evaluates false → the `ADD` is skipped → prefix
B's `phoenix_kit_annotations` ends up with **no** kind check at all.

Also note the guard is pointless for the common single-prefix case: the
`DROP CONSTRAINT IF EXISTS` immediately above already guarantees the constraint
is absent, so an unconditional `ADD` is both correct and simpler.

Fix — either drop the `DO $$` wrapper and `ADD CONSTRAINT` unconditionally
after the DROP, or scope the check: `AND connamespace = '#{schema}'::regnamespace`.
Compare V120's sibling guards in this same PR — they correctly scope on
`table_schema = '#{schema}'`. V121 is the odd one out. (The V119 dimension
migration this was modelled on likely has the same latent bug.)

### IMPROVEMENT - MEDIUM — `:uuid` is now castable on *update*, not just insert — ✅ FIXED

`annotation.ex` adds `:uuid` to `@cast_fields` so client-generated UUIDv7s
survive insert (correct — autogenerate only fires when cast leaves it unset).
But `@adapter_writable_fields = @cast_fields -- [:file_uuid]` now also carries
`:uuid`, and `EtcherAdapter.update/2 → Annotations.update/2 → Annotation.changeset/2`
casts it on the *update* path too. If a payload's `uuid` ever diverges from the
row being updated, Ecto will emit `UPDATE ... SET uuid = $new WHERE uuid = $old`
— a silent primary-key rewrite. In practice the bulk-diff handler passes
matching uuids, so it's latent, but it's a footgun.

Per ecto-thinking ("multiple changesets per schema"): `:uuid` belongs in an
insert-only changeset. Either split `changeset/2` into `create_changeset` /
`update_changeset`, or strip `:uuid` from attrs inside `Annotations.update/2`.

### IMPROVEMENT - MEDIUM — `sync_annotations/3` re-UPDATEs every unchanged annotation — ✅ FIXED

`media_canvas_viewer.ex` — `sync_annotations/3` dispatches per-row work purely
on uuid presence:

```elixir
if Map.has_key?(current_by_uuid, uuid) do
  Storage.EtcherAdapter.update(uuid, a)   # no dirty-check
```

Etcher emits `annotations-changed` with the **full** list on every mutation
(create, drag, color, undo/redo). So a file with N annotations issues N
`UPDATE` statements on every interaction — even a one-shape colour change
rewrites all N rows. Each is its own round-trip (no surrounding transaction).

Diff geometry/style/metadata against `current_by_uuid` before issuing the
update; skip rows that are byte-identical. Worth it once a file accumulates a
handful of annotations.

**Resolution:** `annotation_unchanged?/2` now compares geometry/style/kind and
returns a `:skip` for untouched rows. The post-loop reload (`load_annotations_for`
+ `refresh_file_comments` + `build_viewer_canvas`) is gated on whether any row
was actually created/updated/deleted — a zero-net-change re-broadcast now does
no DB work at all. (`metadata` is intentionally not compared: it's edited via
the composer, not `annotations-changed`.)

### IMPROVEMENT - LOW (verify) — hard-delete of linked comments bypasses the comments context — ⚠️ LEFT FOR DEVELOPER

`annotations.ex` `delete_linked_comments/1` switched from
`PhoenixKitComments.delete_comment/1` to raw `repo.delete(c)`. This skips the
comments context's own delete logic — PubSub events, and crucially any
reply-chain handling. If annotation comments can have threaded replies, and a
reply doesn't carry `metadata.annotation_uuid` (so it's not in the filtered
set) and `phoenix_kit_comments.parent_uuid` lacks `ON DELETE CASCADE`, then
`repo.delete` on the parent raises a `Postgrex.Error` — which the `rescue`
swallows, leaving the annotation gone but its comment thread intact. The commit
message only accounts for `comment_media`, not reply children. Confirm the
comments schema's reply FK before assuming this is safe.

### NITPICK — `creator_uuid` is adapter-writable — ⚠️ LEFT FOR DEVELOPER

`creator_uuid` stays in `@adapter_writable_fields`, so a client payload could
supply it. `sync_annotations/3` calls `creator_attrs(socket)` *after* the
whitelist, overwriting it — fine as long as a current user is always present.
Worth excluding it from the whitelist like `file_uuid` is, so it's
unambiguously server-set.

## Verified OK

- V120 fix is correct: the table-existence guard for
  `phoenix_kit_doc_template_presets` is properly scoped on `table_schema`, and
  matches the existing column-drop guard. Resolves the V120→V121 batch rollback
  on hosts without Document Creator.
- `MediaCanvasViewer.update/2` hydrates annotations once (guarded on
  `viewer_canvas == nil`); LiveComponent `update/2` is the right place for that
  query — no LiveView `mount/3` double-call concern.
- `sync_annotations/3` reloads from DB after writes so comment-derived metadata
  stays fresh; `push_metadata_patches/4` correctly limited to `new_in_batch`.
- Encoding the file uuid in the LC `id` to force a remount on prev/next is the
  right workaround for `<Fresco.canvas>`'s `phx-update="ignore"`.
- `etcher_adapter.ex` cleanly demoted from `@behaviour Etcher.Storage` to a
  plain helper; signatures preserved to keep the call-site diff small.
- Single-root regression test (`media_canvas_viewer_test.exs`) is a genuine
  catch — `rendered_to_string/1` wouldn't surface it.
- `mix.exs` fresco/etcher flipped from path deps to hex pins; `override: true`
  correctly dropped.
