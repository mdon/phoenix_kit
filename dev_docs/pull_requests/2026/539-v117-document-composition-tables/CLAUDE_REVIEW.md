# PR #539 Review — V117: document composition tables

**Status:** Merged (commit `b9da7aa9`). Review for post-merge follow-up.
**Author:** @timujinne
**Scope (declared):** V117 PhoenixKit migration adding the three tables needed by `phoenix_kit_document_creator`:
1. `category VARCHAR` column + index on existing `phoenix_kit_doc_templates`.
2. New `phoenix_kit_doc_document_sections` join table (document ↔ template at ordered positions, per-section variable + image params).
3. New `phoenix_kit_doc_template_presets` table for named reusable section compositions.

The migration itself is straightforward and mirrors prior `doc_*` migrations (V86 / V94 / V110). The headline issues below are about **undeclared scope** in the merge and a CHANGELOG omission — the migration code itself only has cosmetic / belt-and-braces concerns.

---

## BUG — HIGH

### #1 Undeclared scope: PR also reverted the dynamic-`lastmod` sitemap logic on dev

The PR description claims:

> 21 commits (mostly merge-forward from upstream into our dev fork);
> 1 substantive change: lib/phoenix_kit/migrations/postgres/v117.ex + version registry entry.

But the merge commit `b9da7aa9` actually changed **four** files, not two:

```
lib/modules/sitemap/sources/publishing.ex   |  16 +---
lib/modules/sitemap/sources/static.ex       |  23 +----
lib/phoenix_kit/migrations/postgres.ex      |  16 +++-
lib/phoenix_kit/migrations/postgres/v117.ex | 134 ++++++++++++++++++++++++++++
```

The sitemap diff is **not a no-op merge artifact**. Comparing pre-merge dev (`0b561d1b`) against post-merge dev (`b9da7aa9`):

- `lib/modules/sitemap/sources/static.ex`: `static_lastmod/1` (the homepage-and-static `lastmod` helper that walks all publishing groups and falls back to `Date.utc_today/0`) is **removed**. Every static URL now hard-codes `lastmod: Date.utc_today()`.
- `lib/modules/sitemap/sources/publishing.ex`: `latest_post_date/2` is **removed**. Group-listing pages now emit `lastmod: nil`.

**SEO impact:**
- Every static URL in the sitemap (including `/`) now reports `lastmod: <today's date>` on every crawl. Crawlers see "everything was modified today" forever — the signal becomes noise and they back off from re-crawling.
- Group listing pages now ship without `<lastmod>`. Loses the "this group has new posts" hint to crawlers.

**History context (why this matters):**

The relevant timeline on `dev`:

1. `e7b0ef60` (tag `1.7.84`) introduces `static_lastmod/1` + `latest_post_date/2`.
2. `a225f03c` (2026-03-31, "Revert 'Cookie consent fix and sitemap improvements'") removes them.
3. *(several merges later)* — pre-merge `dev` (`0b561d1b`) at the time of PR #539 has `static_lastmod` / `latest_post_date` **back in place** (probably re-introduced via a conflict-resolution favoring the older branch during one of the `Merge upstream/dev` commits in between — `git log a225f03c..0b561d1b -- lib/modules/sitemap/sources/static.ex` shows no direct touches, so the reintroduction was via a merge conflict).
4. PR #539's merge silently re-applies the revert.

So one of two things is true:

- **(a) The third revert is intentional** — the author noticed the previously-reverted code was alive again on dev and wanted it gone. In that case it belongs in the PR title / description / CHANGELOG, not buried in a "V117 migration" PR.
- **(b) It's an accidental side effect** of how the author's fork was rebased — i.e. their fork was branched from a point before step 3's accidental re-introduction, and merging the fork back over `dev` clobbered the live code. In that case it's a regression and should be restored.

Either way, this needs an explicit call. Recommended actions:

- Confirm with @timujinne / @fotkin whether the revert was intended.
- If intended: add an `### Fixed` entry to CHANGELOG 1.7.110 documenting the rollback ("sitemap `lastmod` reverts to `Date.utc_today/0` for static pages and `nil` for group listings — dynamic lastmod proven flaky"), and consider whether the previous `lastmod` regressions that prompted the original revert (cookie consent, etc.) are reason enough to delete the helpers outright (they're already gone now) or to leave a TODO pointing to the design issue.
- If unintended: revert the sitemap deletions and either re-cut a patch release or fold into 1.7.111. Two helpers (`static_lastmod/1` and `latest_post_date/2`) plus the call-sites at `static.ex:202,227` and `publishing.ex:169`.

This is the single biggest concern in the PR — the migration itself is fine, but the merge changed prod-visible SEO behavior with no documentation trail.

---

## IMPROVEMENT — HIGH

### #2 CHANGELOG 1.7.110 has no entry for V117

`CHANGELOG.md` 1.7.110 currently lists only:

- `Fixed` — handle_event/3 in MediaBrowser.
- `Hygiene` — lockfile / precommit / dialyzer cleanups.

V117 is not mentioned at all, even though it is the **headline change** of the version: three new tables, one new column, and a bump of `@current_version` from 116 → 117. Anyone reading the changelog sees a patch-shaped release; anyone running `mix phoenix_kit.update` gets three new tables they don't know about until things break.

Compare against the 1.7.109 entry, which itemizes V114 / V115 / V116 in detail.

Recommended `### Added` bullet for 1.7.110:

```
- V117 migration: document composition tables for `phoenix_kit_document_creator` (PR #539)
  - Adds nullable `category :: varchar` + index to `phoenix_kit_doc_templates` so templates self-classify (financial / technical / etc.) and the template grid can filter by scope
  - Creates `phoenix_kit_doc_document_sections` — join table snapshotting `(document_uuid, template_uuid, position, variable_values, image_params)` for every section of every composed document. `document_uuid → :delete_all` cascades sections with their parent; `template_uuid → :nilify_all` lets sections outlive the template (regenerate-required state). Unique `(document_uuid, position)` + lookup index on `(document_uuid)`
  - Creates `phoenix_kit_doc_template_presets` — named reusable section recipes scoped via `(scope_type, scope_id)` and optionally categorized. `sections` is a JSONB array of `[%{template_uuid, position, variable_values, image_params}]`. Index on `(scope_type, scope_id, category)`
  - Legacy `Document.template_uuid` column is retained: composed docs leave it `NULL`, legacy single-template docs continue to use it
```

Also: if #1 above is resolved as "intentional", add the sitemap reversal as a `### Fixed` (or `### Removed`) bullet in the same release.

---

## IMPROVEMENT — MEDIUM

### #3 Moduledoc claims `DO $$ ... END $$` guards that don't exist

`lib/phoenix_kit/migrations/postgres/v117.ex:24-25`:

> All changes use `IF NOT EXISTS` / `DO $$ ... END $$` guards so re-running on a partially-applied schema is a no-op.

V117 contains **zero** `DO $$ ... END $$` blocks (`grep -n 'DO \\$\\$' v117.ex` returns nothing). It uses:

- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (a Postgres 9.6+ feature),
- `CREATE INDEX IF NOT EXISTS`,
- `create_if_not_exists(table(...))`,
- `CREATE TABLE IF NOT EXISTS`.

These are correct idempotency primitives, but the docstring is copy-pasted from prior migrations (V110 and V116 genuinely use `DO $$` blocks for column-conditional logic). The text is misleading to anyone trying to model future migrations on V117.

Trim the moduledoc to: `All operations use \`IF NOT EXISTS\` guards so re-running on a partially-applied schema is a no-op.`

### #4 `sections JSONB DEFAULT '[]'::jsonb` is expressible in Ecto DSL — raw SQL is unnecessary

`lib/phoenix_kit/migrations/postgres/v117.ex:93-109` falls back to raw `CREATE TABLE IF NOT EXISTS` for `phoenix_kit_doc_template_presets`, with a code comment justifying it:

```elixir
# `sections` is a JSONB array (default '[]'::jsonb), which Ecto's
# `:map` DSL can't express — use raw SQL for that column's default.
```

The same codebase contradicts that claim. `lib/phoenix_kit/migrations/postgres/v86.ex:52` (the original templates migration that **this** migration ALTERs) does exactly that:

```elixir
add(:variables, :map, default: fragment("'[]'::jsonb"))
```

`fragment/1` inside `:map` defaults works for JSONB arrays. Rewriting the presets table in DSL form lets it pick up prefix handling, the unique-index helper, and `create_if_not_exists` consistency without 14 lines of raw SQL. Drop-in:

```elixir
create_if_not_exists table(:phoenix_kit_doc_template_presets,
                       primary_key: false,
                       prefix: prefix
                     ) do
  add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"), null: false)
  add(:name, :string, null: false, size: 255)
  add(:description, :text)
  add(:category, :string)
  add(:scope_type, :string)
  add(:scope_id, :string)
  add(:sections, :map, null: false, default: fragment("'[]'::jsonb"))
  add(:created_by_uuid, :uuid, null: false)

  timestamps(type: :utc_datetime)
end

create_if_not_exists(
  index(:phoenix_kit_doc_template_presets, [:scope_type, :scope_id, :category], prefix: prefix)
)
```

Not blocking (the raw SQL works), but it's the easier-to-maintain form and removes a wrong claim from the comment.

### #5 `created_by_uuid` is `null: false` here but `null: true` on every prior `phoenix_kit_doc_*` table

| Table | `created_by_uuid` nullable? |
|---|---|
| `phoenix_kit_doc_headers_footers` (V86:30) | ✅ nullable (no `null: false`) |
| `phoenix_kit_doc_templates` (V86:77) | ✅ nullable |
| `phoenix_kit_doc_documents` (V86:120) | ✅ nullable |
| `phoenix_kit_doc_document_sections` (V117:77) | ❌ `null: false` |
| `phoenix_kit_doc_template_presets` (V117 raw SQL) | ❌ `NOT NULL` |

V117 introduces a stricter contract than the surrounding tables. Three possibilities:

1. **Intentional tightening.** Fine — but worth a one-line moduledoc justification ("every section / preset must record a creator because deletion-cascade decisions in the consumer need an owner"), and ideally a follow-up to backfill + tighten the existing three tables for consistency.
2. **Reflexive cargo-cult.** Drop `null: false` and match the V86 convention.
3. **Defensive against system-generated rows.** Same as (1) but worth noting that the consumer (`phoenix_kit_document_creator`) is the one enforcing this — V117 itself has no `NOT VALID` / CHECK / FK that would catch a violating insert except `NOT NULL`.

Recommend confirming with @timujinne which one applies; if (1), document the rationale. If (2), relax to nullable.

Related: none of the three tables (old or new) has a FK from `created_by_uuid` to `phoenix_kit_users(uuid)`. Conventional in this codebase, but the dangling-reference risk grows with each new table that snapshots `created_by_uuid`. Not in-scope to fix here — flagging as a known gap.

---

## IMPROVEMENT — LOW

### #6 Redundant index on `phoenix_kit_doc_document_sections`

V117:82-91 creates two indexes:

```elixir
unique_index(:phoenix_kit_doc_document_sections, [:document_uuid, :position], ...)
index(:phoenix_kit_doc_document_sections, [:document_uuid], ...)
```

The unique index on `(document_uuid, position)` is a b-tree, and Postgres can use its leftmost prefix for `WHERE document_uuid = ?` queries. The plain `(document_uuid)` index is redundant for that query shape.

Two cases where the standalone index could earn its keep:

- **Index-only scans** when only `document_uuid` is selected and visibility-map bits permit. The composite index can also serve these.
- **Predicate locking / hot-path optimizer hints.** Negligible at the table sizes this is sized for.

Recommend dropping the `index(:phoenix_kit_doc_document_sections, [:document_uuid], ...)` line. If a benchmark later proves the narrower index helps a hot query, add it back deliberately.

### #7 No `CHECK (position >= 0)` constraint on `phoenix_kit_doc_document_sections`

`position` is `:integer, null: false` — required, but unbounded. A bug in the consumer changeset could persist `position = -1`. Adding `CHECK (position >= 0)` (and/or `<= some-sane-cap`) at the DB level is the belt-and-braces version. Optional.

### #8 Presets index is `(scope_type, scope_id, category)` — won't accelerate category-only filters

V117:111-114:

```sql
CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_presets_scope_index
ON #{p}phoenix_kit_doc_template_presets (scope_type, scope_id, category)
```

This is a leftmost-prefix index — great for queries that filter by `scope_type` (and optionally `scope_id`, and optionally `category`). It does **not** help a "list all presets in category X across all scopes" query, which would have to seq-scan.

If category-only filtering is a real use case (templates have a sibling `category` index added by V117 itself for exactly this query shape), add a standalone `(category)` index on presets too. If it isn't a real use case, ignore.

### #9 Down migration drops `category` column unconditionally — risk of data loss on rollback

`v117.ex:127`:

```elixir
execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS category")
```

Rolling V117 back deletes every value in `phoenix_kit_doc_templates.category`. That's the documented contract of `down/1`, but worth surfacing because:

- The other two destructive operations (dropping the two new tables) are fully reversible — re-running `up/1` recreates empty tables.
- Dropping a *column with content* is not. A rollback after even one user assigns a category loses that data.

PhoenixKit's `Migration` machinery doesn't expose a "down skipped if backfilled" hook, so this can't really be guarded. Just call it out in the moduledoc: `down/1` is destructive — the `category` column is dropped along with all its values.

---

## NITPICK

### #10 `prefix_str/1` helper duplicated across every recent migration

`lib/phoenix_kit/migrations/postgres/v117.ex:132-133` is the third (?) verbatim copy of:

```elixir
defp prefix_str("public"), do: "public."
defp prefix_str(prefix), do: "#{prefix}."
```

Same shape lives in V110, V116, V93, V94, ... Not the moment to refactor (introducing a shared helper would touch every migration), but a future cleanup could lift this into a module-level macro that `use Ecto.Migration` wraps. Out of scope for this PR.

### #11 `phoenix_kit_doc_document_sections` documentation gap: what is a section's content?

The schema persists `(document_uuid, template_uuid, position, variable_values, image_params)` but no `content_html` / `content_css` / `content_native` / `data`. The moduledoc says:

> snapshots `(document_uuid, template_uuid, position, variable_values, image_params)` for every section of every generated document

So rendered content is presumably (a) reassembled at view time by walking sections → template → apply variables, or (b) baked once into a parent `Document.content_html` after composition. The migration doesn't say which, and the design implications are different:

- (a) → template edits propagate to every composed document; "saved" doc is just a recipe.
- (b) → template edits don't propagate; the document is a frozen artifact.

The `template_uuid → :nilify_all` choice hints at (a) ("section survives template removal, content would need regeneration"), but the V86 `Document` schema already has `content_html` columns that the composed flow presumably writes to. Worth a paragraph in either the migration's moduledoc or the consumer schema's moduledoc clarifying which model is canonical.

Not blocking; just future-reader friendliness.

### #12 `prefix_str("public")` returns `"public."` even when the parent migration uses unqualified `phoenix_kit_doc_templates`

Internal nit. `v117.ex:35`:

```elixir
execute("ALTER TABLE #{p}phoenix_kit_doc_templates ADD COLUMN IF NOT EXISTS category VARCHAR")
```

With `prefix = "public"`, `p = "public."`, and the statement becomes `ALTER TABLE public.phoenix_kit_doc_templates ...`. That's correct. But `execute(...)` runs in the migration's `search_path`, so the `public.` qualifier is redundant for the default case. Harmless. The `execute("COMMENT ON TABLE #{p}phoenix_kit IS '117'")` uses the same pattern across every migration — established idiom.

---

## What I checked but didn't flag

- **Migration ordering.** V117 follows V116 (`@current_version 116 → 117`) and matches the version registry shape in `postgres.ex` — fine.
- **Mixed Ecto DSL + raw SQL within one `up/1`.** Already exists in V94 (`google_doc_id` ALTERs via DO $$ + table CREATEs via DSL) — established pattern.
- **`uuid_generate_v7()` fragment.** Standard for the repo; the supporting extension is provided by an earlier migration.
- **`timestamps(type: :utc_datetime)` on the Ecto-DSL table vs `TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL DEFAULT NOW()` on the raw-SQL table.** Both are precision-0 timestamps without timezone — semantically equivalent. The raw-SQL form is fine.
- **The 21 "merge-forward" commits.** Did not audit them individually; the merge stat against pre-merge dev shows only the four files above changed, so any other commits in the fork's history that don't appear in the merge diff are no-ops against dev.
- **`mix precommit`.** Not run locally; per memory, `mix precommit` is the bar for this repo. The CI badge on the merged PR is the source of truth.

---

## Recommended dispositions

| # | Severity | Action |
|---|---|---|
| 1 | BUG-HIGH | Confirm with author whether sitemap revert was intended. If intended → add CHANGELOG note; if not → restore `static_lastmod/1` + `latest_post_date/2` |
| 2 | IMP-HIGH | Add V117 `### Added` entry to CHANGELOG 1.7.110 |
| 3 | IMP-MED  | Fix moduledoc to drop the `DO $$ ... END $$` claim |
| 4 | IMP-MED  | Rewrite `phoenix_kit_doc_template_presets` block in Ecto DSL using `fragment("'[]'::jsonb")` |
| 5 | IMP-MED  | Document `null: false` rationale on `created_by_uuid` (or relax to match V86) |
| 6 | IMP-LOW  | Drop redundant `(document_uuid)` index — composite already covers it |
| 7 | IMP-LOW  | Add `CHECK (position >= 0)` |
| 8 | IMP-LOW  | Decide whether `(category)` standalone index is needed on presets |
| 9 | IMP-LOW  | Add destructive-`down` note to moduledoc |
| 10 | NIT    | Defer — lift `prefix_str/1` into shared helper in a future cleanup |
| 11 | NIT    | Add "what is a section's content" paragraph to moduledoc |
| 12 | NIT    | No action — established repo idiom |

I'll wait on @fotkin's call on #1 (sitemap revert intent) before opening a follow-up PR.
