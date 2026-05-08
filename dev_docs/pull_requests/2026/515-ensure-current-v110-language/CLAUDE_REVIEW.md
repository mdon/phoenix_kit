# PR #515 — `ensure_current/2` helper + V110 `language` column on doc templates

**Author:** @mdon
**Branch:** `dev` ← `dev` (mdon fork)
**Merged:** 2026-05-05T12:38:09Z (`86256b6d`)
**Diff:** +234 / -12 (7 files, 2 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/515

## Verdict

**APPROVE.** Two small, well-scoped changes:

1. **`PhoenixKit.Migration.ensure_current/2`** correctly diagnoses and fixes a latent staleness bug in the documented test_helper migration pattern. The mechanism (fresh `:os.system_time(:microsecond)` version per call, with a static `Runner` module so `Ecto.Migrator.up/4` can resolve `up/0`/`down/0`) is the right shape for this problem and the prefix-forwarding fix in `Runner.runner_opts/0` is a real footgun caught early.
2. **V110** is a straightforward additive nullable column: idempotent `IF NOT EXISTS` guard, comment-bumped marker, no backfill required. Clean.

Findings below are improvements/nitpicks only — nothing blocking, and the fact that this landed with V110 already applied to core's own `phoenix_kit_test` (marker advanced 107 → 110 on first boot per the PR body) is itself an empirical proof point for the helper.

## What changed

| Layer | Before | After |
|---|---|---|
| Test helper | path-form `Ecto.Migrator.run(repo, migrations_path, :up, all: true, log: false)` via wrapper file `test/support/postgres/migrations/20260316000000_add_phoenix_kit.exs` | `PhoenixKit.Migration.ensure_current(PhoenixKit.Test.Repo, log: false)` (wrapper file deleted) |
| Public API | — | `PhoenixKit.Migration.ensure_current/2` + private `PhoenixKit.Migration.Runner` |
| `@current_version` | 109 | 110 |
| `phoenix_kit_doc_templates` | (no `language` column) | `language VARCHAR(10) NULL` |
| AGENTS.md test-infra section | listed migration wrapper directory | points at `test_helper.exs` + warning against the stale tuple form |

## Findings

### IMPROVEMENT - MEDIUM — `migration_test.exs` is spec-shape; the prefix-forwarding fix has no regression coverage

`test/phoenix_kit/migration_test.exs` only asserts that `PhoenixKit.Migration.Runner` exports `up/0`/`down/0`/`__migration__/0` and that `ensure_current/2` is exported. The moduledoc explains the constraint (Ecto.Migrator spawns a separate process whose connection is invisible to the sandbox) and points at empirical "verified at boot" coverage — that's reasonable for the happy-path migrator behaviour.

But the `Runner.runner_opts/0` prefix-forwarding fix is the thing the PR description flags as critical (`prefix: "auth"` silently routed to `"public"` without it). That specific failure mode is purely about which `:prefix` Runner threads through to `PhoenixKit.Migration.up/1` — a regression in `runner_opts/0` (e.g. someone "simplifies" it to `[]`) would not be caught by any current test, and would only surface when a multi-tenant consumer notices tables landing in the wrong schema.

A minimal regression test is achievable without fighting the sandbox: spin up a throwaway non-sandboxed repo against a temp database, call `ensure_current(repo, prefix: "shadow")`, then query `information_schema.tables WHERE table_schema = 'shadow'`. Out of scope for this PR (which is small on purpose), but worth a follow-up.

**Where:** `lib/phoenix_kit/migration.ex:289-294`, `test/phoenix_kit/migration_test.exs:1-57`

### NITPICK — PR body framing pins the blame on a pattern core itself wasn't using

The PR body opens with:

> The pattern shipped in `dev_docs/migration_cleanup.md` and copied into every consuming module's `test_helper.exs`:
>
> ```elixir
> Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)
> ```
>
> is idempotent at the **outer** layer …

Core's own `test/test_helper.exs` was actually using the **path form**:

```elixir
migrations_path = Path.join([__DIR__, "support", "postgres", "migrations"])
Ecto.Migrator.run(PhoenixKit.Test.Repo, migrations_path, :up, all: true, log: false)
```

…which has the *same* staleness bug for the same reason: Ecto.Migrator records `20260316000000` in `schema_migrations` on first run, filters that entry from "pending" forever after, and the wrapper's `up/0` is never re-invoked. The bug analysis itself is correct, just the surface area is broader than the description implies — both list-of-tuples and path forms exhibit it. Cosmetic; doesn't affect the fix.

### NITPICK — `lib/phoenix_kit/migrations/postgres.ex` doc-block ordering

The new `### V110 - Add 'language' to Document Creator templates ⚡ LATEST` block is inserted between V69 and V109, with V109 demoted (loses `⚡ LATEST`) and V108 immediately below it. The migration changelog block has been in non-sequential order since around V72 (V77 also appears out of place), so this PR is just continuing a pre-existing convention — not a defect, but worth noting that the catalogue is now hard to scan. A future cleanup pass to re-sort the entire block descending V110 → V01 would help. Out of scope for this PR.

**Where:** `lib/phoenix_kit/migrations/postgres.ex:529-545`

### NITPICK — `schema_migrations` row accumulates per `mix test` invocation

The PR body acknowledges this ("cosmetic noise acceptable for the test-DB use case"), so flagging it only for the record. Each `mix test` run on a long-lived test DB inserts one row with a fresh microsecond-precision version. ~250 rows/year on a developer machine, nothing on CI (ephemeral DB). Bigint headroom is ~292 years from 2026 — fine.

### NITPICK — `@spec ensure_current/2` claims `:: :ok` but `Ecto.Migrator.up/4` raises on failure

The spec `@spec ensure_current(Ecto.Repo.t(), keyword()) :: :ok` is technically correct in that the function only ever *returns* `:ok` — anything else is a raise propagating from `Ecto.Migrator.up/4` (advisory-lock failure, migration crash, etc.). Dialyzer is happy with this. Just noting that callers wrapping it in `try/rescue` should be aware the contract is "raise on failure", not "return `{:error, _}`". The moduledoc could call this out one-liner-style, but not load-bearing.

## What's good

- **Static `Runner` module at module scope** — the comment on `lib/phoenix_kit/migration.ex:267` is exactly right: an anonymous module defined per call wouldn't let `Ecto.Migrator.up/4` resolve `up/0` against a known module name. This was the right call.
- **Microsecond precision over millisecond** — the inline comment on `migration.ex:238-243` walks through the trade-off explicitly (1000× smaller collision/clock-skew window, still fits in `bigint` for ~292 years). Honest reasoning, not magic numbers.
- **`runner_opts/0` defends against `prefix: nil`** — the comment on `migration.ex:284-288` correctly identifies that `with_defaults/2` in `PhoenixKit.Migrations.Postgres` uses `Enum.into` which doesn't override an existing `nil` value with the `"public"` default, and would crash at `String.replace(nil, "'", "\\'")`. Subtle bug, well-handled.
- **V110 idempotency** — the `DO $$ … IF NOT EXISTS … ALTER TABLE … END $$` shape correctly handles re-runs without column-already-exists errors. Same shape as recent migrations (V107, V108, V109).
- **V110 down is honest about data loss** — `DROP COLUMN IF EXISTS language` with no preservation. Correct for an additive nullable column rollback; preserving values into JSONB or similar would be over-engineering for an emergency-only path.
- **No schema/API churn in core for V110** — the PR explicitly defers the Ecto schema change (`field :language, :string` in the Document Creator template module) to the external `phoenix_kit_document_creator` repo. Core only owns the migration; the column is nullable, so the schema staying behind doesn't break anything until that repo lands its update. Clean separation of concerns.
- **AGENTS.md update** — the new `test/test_helper.exs` entry includes the **Do not** warning against the stale tuple form, which is the right level of friction for the next agent or contributor who'd otherwise reach for the documented (but broken) pattern.

## Verified locally

- Diff fetched via `gh pr view 515 --json files,additions,deletions` — matches the in-tree merge commit `86256b6d` parent diff.
- Read-through of `lib/phoenix_kit/migration.ex`, `lib/phoenix_kit/migrations/postgres/v110.ex`, `lib/phoenix_kit/migrations/postgres.ex`, `test/phoenix_kit/migration_test.exs`, `test/test_helper.exs`.
- Cross-checked `Ecto.Migrator.run/3,4` and `Ecto.Migrator.up/4` semantics: `up/4` does record the synthetic version in `schema_migrations` (so PG's bigint accumulation is real), but PhoenixKit's table-comment marker is the actual short-circuit gate inside `PhoenixKit.Migrations.Postgres.up/1` — so re-runs are cheap on already-current DBs.
- Confirmed no other callers of the (now-buggy) `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], …)` pattern remain in `lib/` or `test/` (`grep` for `Migrator.run|Migrator.up`).

## Suggested next step

Bump `@version` 1.7.103 → 1.7.105 and add a CHANGELOG entry covering both items (helper + V110). CHANGELOG ownership is the maintainer's per AGENTS.md — flagging the gap, not auto-writing it.

## Follow-up commit on `dev` (post-merge, this review)

Three small changes addressing the **IMPROVEMENT - MEDIUM** finding above and the moduledoc nitpick. CHANGELOG entry intentionally left for the maintainer.

### 1. Make `Runner.runner_opts` testable (`lib/phoenix_kit/migration.ex`)

Split the previous closure-style `runner_opts/0` (which read `prefix()` from the live `Ecto.Migration.Runner` process state) into a pure `runner_opts/1` that takes the prefix as an argument. `Runner.up/0` and `Runner.down/0` now call `runner_opts(prefix())`.

```elixir
def up, do: PhoenixKit.Migration.up(runner_opts(prefix()))
def down, do: PhoenixKit.Migration.down(runner_opts(prefix()))

@doc false
def runner_opts(nil), do: []
def runner_opts(prefix), do: [prefix: prefix]
```

This is the minimum surface change to let the prefix-forwarding behaviour be regression-tested without spinning up a real `Ecto.Migration.Runner` (which would conflict with the sandbox, per the test moduledoc). The `@doc false` keeps `runner_opts/1` out of generated docs while still making it callable from tests.

### 2. Add unit tests for the prefix-forwarding regression (`test/phoenix_kit/migration_test.exs`)

Three new assertions in a `describe "Runner.runner_opts/1 (prefix forwarding)"` block:

| Input | Expected output | Why |
|---|---|---|
| `nil` | `[]` | `with_defaults/2` uses `Enum.into` which would let a literal `prefix: nil` clobber the `"public"` default and crash inside `String.replace(nil, "'", "\\'")` |
| `"auth"` | `[prefix: "auth"]` | Multi-tenant migrations must land in the caller's schema, not silently in `public` |
| `"tenant_42"` | `[prefix: "tenant_42"]` | Same, generalised |

If someone "simplifies" `runner_opts/1` to always return `[]` (the original bug shape the helper was added to prevent), CI now fails — closing the gap the review flagged.

### 3. Document the `ensure_current/2` raise-on-failure contract (`lib/phoenix_kit/migration.ex`)

Added a "Return contract" section to the `ensure_current/2` moduledoc:

> Returns `:ok` on success. Failures (advisory-lock contention, migration crashes, connection errors) propagate as raises from `Ecto.Migrator.up/4`; `ensure_current/2` does not wrap them in `{:error, _}`.

One-paragraph addition; the spec was already accurate (`:: :ok`), this just calls out the failure-mode contract for callers wondering whether to wrap in `try/rescue`.

### 4. Version bump (`mix.exs`)

`@version` `1.7.104` → `1.7.105`. CHANGELOG entry deferred to the maintainer per AGENTS.md ownership rules.

### Verification

`mix precommit` clean: `mix compile` (no warnings), `mix format --check-formatted` (clean), `mix credo --strict` (0 issues), `mix dialyzer` (0 errors).
