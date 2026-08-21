# Claude Review — PR #743 "Federated party references for the catalogue (V178–V180)"

**Merge commit:** e1778ddea79bbadd49aad7a5e61ab3635aa7e40b
**Author:** mdon (feat/crm-party-federated-references)
**Files:** `AGENTS.md`, `lib/phoenix_kit/migrations/expected_schema.ex`, `lib/phoenix_kit/migrations/postgres.ex`, `lib/phoenix_kit/migrations/postgres/v178.ex`, `v179.ex`, `v180.ex`, `priv/gettext/et,ru/LC_MESSAGES/default.po`, `test/integration/hand_declared_manifest_test.exs`

## Summary of the change

Three migrations move the catalogue's manufacturer/supplier graph from hard
local foreign keys to CRM-federated soft references, matching the shape
`phoenix_kit_cat_item_supplier_info.supplier_uuid` has used since V149:

- **V178** — adds `phoenix_kit_cat_manufacturers.crm_company_uuid` (nullable,
  no FK — optional-module boundary) plus partial unique indexes on both
  `cat_manufacturers` and `cat_suppliers`' `crm_company_uuid`, so each
  directory stays one-to-one against a CRM party. Additive only.
- **V179** — `phoenix_kit_cat_items.manufacturer_uuid` becomes a federated
  reference: adds `manufacturer_source` (`local`/`crm_company`, CHECK-backed)
  and `manufacturer_name_snapshot` (a tombstone, read only when the
  reference resolves to nothing), and **drops**
  `phoenix_kit_cat_items_manufacturer_uuid_fkey`.
- **V180** — does the same for the M:N `phoenix_kit_cat_manufacturer_suppliers`
  join (adds `manufacturer_source`/`supplier_source`, drops both FKs — which
  carried `ON DELETE CASCADE`), and rides along a second, unrelated
  tightening: a partial unique index
  `(item_uuid, supplier_uuid) WHERE valid_to IS NULL` on
  `phoenix_kit_cat_item_supplier_info` so an item can't carry two *open*
  price rows for the same supplier. Pre-existing duplicates are closed
  (not deleted) via a ranked dedupe (primary wins, else oldest, `uuid` as
  total tiebreak) under a `SHARE ROW EXCLUSIVE` table lock, so the unique
  index build can't race a concurrent writer into failing.

All three are additive/idempotent (`ADD COLUMN IF NOT EXISTS`, `DO $$ IF NOT
EXISTS`-guarded constraints, `DROP ... IF EXISTS`), with `down/1` that
restores the FKs and raises loudly (not silently) if any row now references a
CRM party the restored FK can't satisfy. `expected_schema.ex`'s three
hand-declared blocks (`chain_hash` bumped) match the migration SQL exactly —
verified column positions, defaults, CHECK constraint text, and index
predicates field-by-field against the migration source, and independently
against a live database (see Validation below). The two now-optional FKs
(V179's on `cat_items`, V180's two on `cat_manufacturer_suppliers`) are
correctly flipped from `presence: :required` / a `create` SQL string to
`presence: :legacy_optional` / `create: nil`, which is what stops `mix
phoenix_kit.repair` from fighting the migration by recreating a FK it just
dropped.

## Findings

### 1. MEDIUM — the migration's own justification for dropping `ON DELETE CASCADE` isn't true yet in the consuming module

The V180 moduledoc states:

> Application-level cleanup, deliberately. The dropped constraints carried
> `ON DELETE CASCADE`, so deleting a local supplier or manufacturer used to
> clear its links for free; `Catalogue.delete_supplier/2` and
> `delete_manufacturer/2` now delete them explicitly.

I checked `phoenix_kit_catalogue` (the only consumer of this table) at its
current `main` (`6118e57`): `Manufacturers.delete_manufacturer/2` and
`Suppliers.delete_supplier/2` both still do a bare `repo().delete(...)` with
no cleanup of `phoenix_kit_cat_manufacturer_suppliers` rows. The link-cleanup
code the moduledoc describes lives in `phoenix_kit_catalogue` **PR #75**
("Suppliers and manufacturers become CRM parties"), opened today by the same
author and still **open/unmerged** — it adds
`delete_manufacturer_supplier_links_for/1` and wires it into both delete
paths (confirmed via `gh pr diff 75`).

**Practical effect:** core is correct and safe standalone — nothing in this
repo calls those delete functions. But any install running
`phoenix_kit_catalogue` at its pre-#75 version, once migrated to V180, will
silently **orphan** `phoenix_kit_cat_manufacturer_suppliers` rows (pointing at
a manufacturer/supplier uuid that no longer exists) on any local
supplier/manufacturer delete — the CASCADE that used to clean this up for
free is gone, and nothing replaced it yet. This is a data-integrity gap, not
corruption (the orphaned rows are inert and recoverable by a backfill once
#75 lands), and it's scoped to an opt-in module.

**Not fixed here** — the fix belongs in `phoenix_kit_catalogue` (a separate
repo/package), which already has it queued in an open PR. Per the user's
explicit decision, this phoenix_kit release ships with the risk flagged
rather than held; see the CHANGELOG entry for the operator-facing note.
**Action for next session:** confirm `phoenix_kit_catalogue` #75 merges and
publishes promptly, and that its own CHANGELOG calls out upgrading past this
point before deleting local suppliers/manufacturers on a V180+ install.

### 2. LOW (fixed) — new test broke `mix precommit`

`test/integration/hand_declared_manifest_test.exs:50` chained two
`Enum.filter/2` calls (`|> Enum.filter(...) |> Enum.filter(...)`), which
`credo --strict`'s `Credo.Check.Refactor.FilterFilter` flags as a refactor
opportunity — and `quality.ci` (part of `mix precommit`) fails the build on
any credo finding under `--strict`. Merged as-is, this PR left `mix
precommit` red.

**Fixed:** merged the two filters into one predicate
(`&(&1.severity in [:error, :repairable] and (&1.since || 0) >= @hand_declared_from)`),
reformatted by `mix format`. `mix precommit` is clean after the fix.

## Validation

- `PGDATABASE=phoenix_kit_test mix test.setup`-equivalent (via
  `mix ecto.migrate`) ran the real chain V178→V180 against a live Postgres —
  clean, no errors.
- `test/integration/hand_declared_manifest_test.exs` (new in this PR) — 2
  tests, 0 failures, confirming the hand-declared V178+ manifest entries
  match what the migrations actually build on a real database.
- `test/integration/prefix_migration_test.exs` — passes with the chain
  through a named schema prefix.
- `test/integration/phoenix_kit_web/live/settings/authorization_secret_leak_test.exs`
  (PR #742) — 4 tests, 0 failures.
- Full `mix test` — **43 doctests, 3931 tests, 0 failures**.
- `mix precommit` (compile --warnings-as-errors, `deps.unlock --check-unused`,
  `quality.ci` — format, `credo --strict`, `dialyzer` — plus JS tests) —
  **clean**, after finding #2's fix.

## Verdict

One fix applied (credo violation in the new test). One finding documented
and deliberately not fixed here (cross-repo dependency gap in
`phoenix_kit_catalogue`) — flagged to the user, who chose to publish with the
risk noted rather than hold the release.
