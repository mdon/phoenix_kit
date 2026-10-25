# Module tables: every module owns its own

**Status:** in progress — step 1 done (unreleased), step 2 next. See the
[progress log](#progress-log).
**Started:** 2026-10-25. **Tracks:** this file is the shared record of where
the work stands; update it in the same commit as each step.

Builds on [the module-table extraction guide](../guides/2026-09-05-module-table-extraction-guide.md)
(its Phase 0 / 1 / 2) and finishes it for every module, instead of inventing a
new protocol.

## Where we want to end up

- Each module's tables are created and changed **only** by that module's own
  migration chain.
- Core's migrations, `ExpectedSchema` manifest and runtime code know only
  core's own tables.
- A fresh install gets only the tables of the modules it installs.
- The manifest is generated from the chain, never written by hand.

## Why (found 2026-10-25)

- Core's chain creates **181 tables**: **40 are core's**, **141 belong to 25
  modules** — they were created when those modules lived inside core.
  `PhoenixKit.Migrations.ModuleOwnedTables` now records whose each one is.
- After the 2.0 squash, **36 of the 88 core versions (V136–V223) still created
  or changed module tables** — most recently V188 (user connections), V193 and
  V223 (AI requests), V218 (sync connections).
- `ExpectedSchema` (`lib/phoenix_kit/migrations/expected_schema.ex`) describes
  all 181 tables: 76,782 lines, 3,632 entries, about 1,500 of them module
  tables. Every new table costs ~1,000 hand-written lines; it grew by ~10,000
  lines in 2.5 months. Loading it adds ~6.4 MB to every node that runs a release.
  Only `mix phoenix_kit.repair`, `mix phoenix_kit.doctor` and
  `mix phoenix_kit.release_check` use it.
- Modules fall into four groups (inventory below): 6 have no migrations at all,
  2 depend on core for some tables, 17 adopted their tables but core still
  creates them first, 6 are fully independent.

## Rules for the whole project

- Follow the extraction guide's protocol; extend it, don't replace it.
- **Nothing destructive.** No table is dropped by anyone except through an
  explicit decision for that table (step 9).
- **Existing hosts see no schema change until step 8**, and step 8 affects only
  fresh installs: V135 never runs on an existing host, and hosts below V135
  are refused (`BelowFloorError`).
- One step = one unit of work, gated (`mix precommit` + full `mix test`),
  shipped on the weekly release day.

## Steps

| # | Step | Where | Status |
|---|---|---|---|
| 1 | Ownership map + guard test + rule in the docs | core, hello_world | **Done** 2026-10-25 (unreleased) |
| 2 | "Builds from scratch" test helper + a true fresh-install test | core | Not started |
| 3 | First migration chain for comments, staff, user_connections, sync, calendar, referrals | 6 modules | Not started |
| 4 | Complete the chains of ai (3 tables) and document_creator (7 tables) | 2 modules | Not started — ai needs its owner's agreement |
| 5 | The step-2 test in every adopted module; fix what it finds | 17 modules | Not started |
| 6 | Core's manifest hands every module-owned entry over | core | Not started |
| 7 | Manifest generator (frozen pre-squash part + generated rest, compact, in `priv/`); move core's hard-coded module-table lists to module callbacks | core | Not started |
| 8 | Core stops creating module tables on fresh installs | core | Not started — approach to decide |
| 9 | Dead tables (`crm_user_role_view`, `email_metrics`, `email_orphaned_events`) | crm, emails | Not started — per-table decision |

### Step 1 — ownership map and guard (done)

- `PhoenixKit.Migrations.ModuleOwnedTables` (`lib/phoenix_kit/migrations/module_owned_tables.ex`):
  `core_tables/0` (40), `owners/0` (141 tables under 25 OTP apps), `owner/1`,
  `tables_for/1`, `last_core_version_touching_module_tables/0` (223).
  Ownership follows the code: the package with the Ecto schema, or the module
  whose chain adopts a schema-less table. 63 manifest `owner:` labels disagree
  (57 say `:core`, 6 say `:comments` for posts' and customer support's tables);
  the list is the authority.
- `test/phoenix_kit/migrations/module_owned_tables_test.exs` (no database): every
  table core's chain creates is classified exactly once; **no core version after
  V223 names a module table in its code** (parsed source, so comments and docs
  don't count); the scan is proven on V223 and on a synthetic version.
- Docs: core `AGENTS.md` (Database), the extraction guide's inventory,
  hello_world's README (the template's database conventions), workspace `AGENTS.md`.

### Step 2 — prove a module can build its tables alone

A helper core ships in `lib/` (like `PhoenixKit.TestSupport.PostgresPreflight`)
for module test suites: in a scratch schema, run core's chain, drop the
module's tables, run the module's chain, and compare the module's tables
(columns, types, defaults, nullability, indexes, constraints and their names)
with what core built, using repair's catalog snapshot. Plus a core test that
builds a database **from nothing** and compares it with the incrementally
migrated one — `phoenix_kit_billing` reports `phoenix_kit_subscriptions.subscription_type_uuid`
missing on from-scratch builds; this test settles that first.

Done when: the helper is released, documented in the extraction guide, and
used by at least one module as the worked example.

### Step 3 — six modules get their first chain

comments, staff, user_connections, sync, calendar, referrals. Each copies the
hello_world coordinator: V1 adopts its tables with `CREATE … IF NOT EXISTS`,
shape- and name-identical to what core builds **today** (including core's later
changes: V136, V141, V164, V166, V188, V218), stamps a marker, `down/1` only
unstamps; the step-2 test proves it. comments and staff first (most dependents).

### Step 4 — ai and document_creator

ai's chain says endpoints, prompts and requests "stay in core's chain"; agree a
move with ai's owner first (core still changed `ai_requests` in V223, which ai's
V4 requires). document_creator's chain creates only its taxonomy table; its
other 7 come from V135.

### Step 5 — the 17 adopted modules

Add the step-2 test to each; any whose chain cannot really build its tables
alone gets fixed. This is where hidden gaps surface.

### Step 6 — core's manifest lets go

Remove every module-owned object from `ExpectedSchema` (the guide's Phase 1 for
all of them at once), using `ModuleOwnedTables`; `doctor`/`repair` then check
core's tables only. Requires steps 3–5, so each module can vouch for its own
tables. Later, step 7's generator can produce a manifest per module so repair
checks module tables again, owned by the module this time.

### Step 7 — generated manifest

Split the manifest: a frozen part for what only the pre-squash chain could know
(entries born at or below V135, their old revisions, `legacy_optional`) and a
part generated by replaying V135→head with `generate_baseline.exs`'s catalog
snapshots. One line per object, stored in `priv/` and read only when repair or
doctor runs, with a test that fails when it is stale. Also move core's
hard-coded module-table lists (storage's orphaned-file check, doctor's
NULL-uuid check) to module callbacks.

### Step 8 — core stops creating module tables (fresh installs only)

Remove the module DDL from V135 and from the later versions that touch module
tables. Risk: a fresh install of new core with an old module version that has
no chain. Options, decided when we get here:

- **(a) at core 3.0** — modules pin `< 3.0.0`, so a 3.0 install always has module
  versions with their own chains. Recommended.
- **(b) in 2.x** — core still creates a module's tables when that module's
  loaded version does not claim them.

### Step 9 — dead tables

`phoenix_kit_crm_user_role_view` (CRM copied it into core's view preferences,
V7), `phoenix_kit_email_metrics` and `phoenix_kit_email_orphaned_events` (no
reader). Dropping deletes data: an explicit decision per table, done in the
owning module's chain, never core's.

## Decisions

| Decision | Status |
|---|---|
| Follow the extraction guide; no new protocol | Made 2026-10-25 |
| Ownership authority is `ModuleOwnedTables`, not the manifest's `owner:` labels | Made 2026-10-25 |
| `phoenix_kit_consent_logs` is legal's (legal's chain owns its shape; core still creates it) | Made 2026-10-25 |
| ai's endpoints/prompts/requests move to ai (step 4) | Open — ai's owner |
| Step 8: (a) at 3.0 or (b) in 2.x | Open |
| Step 9: drop or keep each dead table | Open |

## Progress log

- **2026-10-25** — Investigation (manifest, table ownership, migration
  dependencies) and this plan. Step 1 done: `ModuleOwnedTables`, the guard test,
  docs (core, hello_world). Gate: `mix precommit` clean; full suite 89 doctests,
  12,780 tests, 0 failures (21 skipped, `:requires_createrole` excluded).
  Unreleased; ships with core's next release.

## Inventory (2026-10-25)

Tables core's chain creates, by owner. "Core changed after V135" lists the core
versions whose code names the module's tables.

**No migrations of their own (step 3):**

| Module | Tables | Core changed after V135 |
|---|---|---|
| comments | 4 | V164, V166 |
| staff | 7 | V136 |
| user_connections | 6 | V188 |
| sync | 2 | V218 |
| calendar | 2 | V141 |
| referrals | 2 | — |

**Partly on core (step 4):** ai — 3 of its 8 tables (V169, V193, V223);
document_creator — 7 of 8 (none after V135).

**Adopted, but core still creates them first (step 5):** billing 11,
catalogue 18, posts 13, crm 10, ecommerce 10, warehouse 8, publishing 7,
emails 6, projects 6, customer_support 4, locations 4, manufacturing 3,
entities 2, newsletters 2, open_graph 2, dashboards 1, legal 1.

**Fully independent:** agent, boards, bookings, inbox, stats, web_analytics
(and ai's five newer tables).

The full table-by-table list is `PhoenixKit.Migrations.ModuleOwnedTables`.
