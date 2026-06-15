# PR #594 — V135: structured staff skills + per-skill dynamic proficiency levels

**Status:** MERGED to `main` (`a3cedc10`, merge of `bde8a528`). Retrospective
review. **V135 is unreleased** (mix.exs is still `1.7.148`; `@current_version`
bumped to 135 but no version bump / Hex publish / tag followed). That matters
for the finding below: because no production DB has run V135 yet, the fix can
**amend `v135.ex` in place** — exactly the amend-while-unreleased pattern Max
used across the PR's own three commits — rather than requiring a V136
migration. DBs that already ran V135 (consumer CI, devs on `main`) re-run
nothing (`135 > reported_version` is false in `ensure_current/2`); DBs that
haven't run it yet get the hardened first-run path.

**Scope:** 2 files, +184 / −2. One new versioned migration (`v135.ex`) +
`@current_version` 134 → 135 and the V135 doc block in `postgres.ex`. Creates
`phoenix_kit_staff_skills` + `phoenix_kit_staff_person_skills`, migrates the
free-text `phoenix_kit_staff_people.skills` column into structured rows,
strips the orphaned per-locale `translations[...]["skills"]` overrides, and
adds a partial birthday index. Purely additive core-side (no core runtime
depends on it).

## Verification done in this review

Cross-checked the migration's contract against the consumer
(`phoenix_kit_staff`, already merged at `75dbaf8`) and the table owner (core
V100). Everything that could have been wrong, isn't:

- **Table ownership.** V135 references `phoenix_kit_staff_people`, which V100
  *creates* (core owns the whole staff schema — departments/teams/people/
  memberships). So the unguarded `REFERENCES phoenix_kit_staff_people(uuid)`
  is safe for *every* core host, even ones without the consumer installed —
  consistent with V100/V101/V122/V128/V131. Not a cross-module hazard.
- **Column types line up.** `people.uuid` is `UUID` (V100) → FK type-correct.
  `people.skills` is `TEXT`, `people.translations` is JSONB, `people.status`
  is `VARCHAR(20) DEFAULT 'active'`, `people.date_of_birth` is `DATE` — all
  match what V135 reads/alters. `skills` is in the consumer's
  `@translatable_fields`, so the "strip `translations[locale]["skills"]`"
  step targets a key that actually exists (accurate moduledoc, not aspirational).
- **Partial index is actually usable.** `Staff.upcoming_birthdays/1`
  (`phoenix_kit_staff/staff.ex:284`) filters
  `p.status == "active" and not is_nil(p.date_of_birth)` → compiles to exactly
  `status = 'active' AND date_of_birth IS NOT NULL`, which *implies* the
  index predicate. Postgres can use it. (The anniversary-window fragment
  isn't sargable on `date_of_birth`, so the win is "scan the active+non-null
  subset," not a tight range lookup — still correct and never worse than a
  seq scan.)
- **Join timestamps are intentional.** `person_skills` has `inserted_at`
  only, no `updated_at` — and the consumer's `PersonSkill` schema declares
  `timestamps(type: :utc_datetime, updated_at: false)`. Match is deliberate,
  not an oversight (proficiency rewrites go through the context; the row's
  mtime isn't tracked by design).
- **JSONB↔`{:array, _}` shapes match.** `Skill.levels` is
  `{:array, :map}` ↔ `levels JSONB`; `PersonSkill.proficiency_levels` is
  `{:array, :string}` ↔ `proficiency_levels JSONB`. Postgrex JSON-encodes the
  list param for a jsonb column regardless of inner Ecto type — the schema
  comment calls this out and it round-trips.
- **Idempotency / retry-safety** is sound: `CREATE … IF NOT EXISTS`,
  `DROP … IF EXISTS`, and the `DO $$ … IF EXISTS (columns.skills) $$` guard
  (PL/pgSQL plans the inner statements lazily, so a re-run after the DROP is
  a genuine no-op, not a parse error on the dropped column). Partial-run
  recovery works because the INSERTs use `ON CONFLICT … DO NOTHING` and the
  translations strip is idempotent.
- **`down/1`** drops the partial index, re-adds `skills TEXT` (matches V100's
  original type), drops the join before the skills table (FK order), and lets
  `DROP TABLE` cascade the dependent indexes. Lossy rollback (empty
  `skills`, structured rows destroyed) — clearly documented.

Data-migration logic (case-insensitive cross-person dedup via
`DISTINCT ON (lower(trim(tok)))`, link-by-lowercased-name, per-locale key
strip via `jsonb_each` + `submap - 'skills'`) is correct and handles NULL
skills, empty/whitespace tokens, intra-person dupes, and NULL translations.

**One BUG found (low likelihood, high blast radius, trivial fix).** Details
below.

---

## BUG - MEDIUM — Data migration can wedge on a >255-char skill token (`skills.name` is `VARCHAR(255)`, source column is `TEXT`)

V100 created `phoenix_kit_staff_people.skills` as **`TEXT`** (unbounded, line
77). V135 creates `phoenix_kit_staff_skills.name` as **`VARCHAR(255)`**, and
the consumer's `Skill` changeset enforces `validate_length(:name, min: 1, max: 255)` —
so 255 is the intended contract.

The data-migration INSERT copies tokens verbatim with no length cap:

```sql
INSERT INTO #{p}phoenix_kit_staff_skills (name)
SELECT DISTINCT ON (lower(trim(tok))) trim(tok)
FROM #{p}phoenix_kit_staff_people pers
CROSS JOIN LATERAL regexp_split_to_table(pers.skills, ',') AS tok
WHERE pers.skills IS NOT NULL AND trim(tok) <> ''
ORDER BY lower(trim(tok)), trim(tok)
ON CONFLICT (lower(name)) DO NOTHING;
```

A single free-text token longer than 255 chars →
`ERROR: value too long for type character varying(255)`. Ecto wraps `up/1` in
a DDL transaction, so it rolls back cleanly (no partial state) — but
`ensure_current/2` will fail the same way on every retry, so the host is
**wedged on V135**: releases/deploys fail until someone manually truncates the
offending row. Every core host runs this migration.

**Likelihood: very low** — real staff skills are short ("Excel", "First Aid",
"Forklift License"). Nobody types a 256-char skill. **Impact if hit: high** —
core migration wedge, manual data surgery to clear. **Fix: one-liner.** Cap
the token at insert time so the raw-SQL path honors the same 255 contract the
changeset does:

```sql
SELECT DISTINCT ON (lower(LEFT(trim(tok), 255))) LEFT(trim(tok), 255)
...
ORDER BY lower(LEFT(trim(tok), 255)), LEFT(trim(tok), 255)
```

(`LEFT(...,255)` in all three places — the `DISTINCT ON` expr, the selected
value, and the matching `ORDER BY` prefix — so dedup stays consistent on the
truncated form.) The link INSERT is unaffected (joins on `lower(name)` =
`lower(trim(tok))`, still matches the truncated row).

**Recommendation:** amend `v135.ex` now while V135 is unreleased. If you'd
rather not touch the merged migration, the alternative is a V136 no-op guard
— but that's heavier than this deserves for an unreleased migration.

---

## NITPICK — Canonical-casing tie-break leans uppercase (deterministic, cosmetic)

`DISTINCT ON (lower(trim(tok))) … ORDER BY lower(trim(tok)), trim(tok)`
resolves a casing clash ("Excel" vs "EXCEL" vs "excel") by taking the
`trim(tok)` that sorts first — and uppercase ASCII sorts before lowercase, so
the canonical form leans upper ("EXCEL" wins over "Excel"). Deterministic,
which is what matters for retry-safety; just not the "most common" or
"prettiest" casing. Not worth changing on its own — fold into the truncation
edit above only if you're already in there.

---

## Positive notes

- `uuid_generate_v7()` everywhere (matches the "new migrations use v7" rule).
- FK cascade semantics are right on both sides (`ON DELETE CASCADE` from
  person and from skill → deleting either cleans the join).
- Index coverage is complete for both directions: composite
  `(staff_person_uuid, skill_uuid)` serves "person's skills," standalone
  `(skill_uuid)` serves "who has this skill."
- The `DO $$ … IF EXISTS (columns.skills) $$` guard with a clear comment on
  *why* PL/pgSQL lazy planning makes it retry-safe is exactly the right
  defensive pattern.
- Moduledoc honestly documents the lossy edges (per-locale overrides
  stripped, rollback empty) instead of papering over them.
