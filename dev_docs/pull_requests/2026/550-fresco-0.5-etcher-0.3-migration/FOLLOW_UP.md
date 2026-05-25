# Follow-up — PR #550 (Fresco 0.5 + Etcher 0.3 migration / annotations)

## Fixed (pre-existing — verified, no new work needed)

- ~~**BUG-MEDIUM** — V121 constraint guard ignored table prefix/schema.~~ Fixed in commit `5198eb3d` ("Fix annotation migration + persistence issues from PR #550 review"). `lib/phoenix_kit/migrations/postgres/v121.ex:10-22` now uses unconditional `DROP IF EXISTS` immediately before each `ADD`.
- ~~**IMPROVEMENT-MEDIUM** — `:uuid` was castable on update.~~ Fixed in the same commit (`5198eb3d`). `lib/phoenix_kit/annotations/annotations.ex:212` strips `:uuid` from attrs before changeset on update via `Map.drop(attrs, [:uuid, "uuid"])`.
- ~~**IMPROVEMENT-MEDIUM** — `sync_annotations/3` re-UPDATEd unchanged annotations.~~ Fixed in `5198eb3d`. `lib/phoenix_kit_web/components/media_canvas_viewer.ex:166,243` implements an `annotation_unchanged?/2` dirty-check on geometry/style/kind; lines 218-233 gate the reload on `wrote? or to_delete != []`.

## N/A

- **IMPROVEMENT-LOW** — Hard-delete of linked comments bypasses context. Intentional design — the annotation/comment relationship is one-way (annotation owns; comments back-reference via `metadata.annotation_uuid`), documented in `lib/phoenix_kit/annotations/annotation.ex:10-18` moduledoc.

## Fixed (Batch 1 — 2026-05-25)

- ~~**NITPICK** — `creator_uuid` adapter-writable.~~ Added `:creator_uuid` to the `--` exclusion list in `@adapter_writable_fields` at `lib/phoenix_kit/annotations/annotation.ex:62`. Mirrors `:file_uuid`'s exclusion — the adapter resolves the creator from actor opts server-side, so a forged event payload can't claim authorship.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit/annotations/annotation.ex` | Excluded `:creator_uuid` from adapter-writable whitelist |

## Verification

- `mix compile --warnings-as-errors` clean (via `phoenix_kit_parent`)

## Open

None.
