# PR #514 — Extract Customer Service module and rename to Customer Support

**Author:** @timujinne
**Branch:** `dev` ← `dev` (timujinne fork)
**Merged:** 2026-05-04T17:03:02Z (`54b976f3`)
**Diff:** +549 / -6020 (36 files)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/514

## Verdict

**APPROVE.** Clean two-step refactor: (1) extract the in-tree `lib/modules/customer_service/` tree (~6 KLOC, 22 files) into the standalone `phoenix_kit_customer_support` package; (2) rename the public surface from "Customer Service" → "Customer Support" with a V109 data migration. `mix compile --warnings-as-errors` is clean, no orphan `customer_service` references remain outside migrations, and the only callers in core (router glue, anonymizer, dashboard nav target) are repointed correctly.

A handful of nitpicks below; nothing blocking.

## What changed

| Layer | Before | After |
|---|---|---|
| Module ref | `PhoenixKitCustomerService.*` | `PhoenixKitCustomerSupport.*` |
| OTP app | `:phoenix_kit_customer_service` | `:phoenix_kit_customer_support` |
| Hex package | `phoenix_kit_customer_service` | `phoenix_kit_customer_support` |
| Settings keys | `customer_service_*` (7 keys) | `customer_support_*` |
| Permission key | `customer_service` | `customer_support` |
| URL paths | `/customer-service/*` | `/customer-support/*` |
| Dashboard tile | "Customer Service" | "Customer Support" |
| `@current_version` | 108 | 109 |

DB tables (`phoenix_kit_tickets`, `phoenix_kit_ticket_*`) are domain-named and stay put — correct call.

## Findings

### IMPROVEMENT - MEDIUM — V108 missing from docstring; ⚡ LATEST flow

`lib/phoenix_kit/migrations/postgres.ex` has a per-version docstring catalog. PR #512 (V108 DnD core) bumped `@current_version` 107 → 108 but did **not** add a `### V108 …` section to the docstring or move the `⚡ LATEST` marker off V107. This PR's V109 entry then "moves" `⚡ LATEST` from V107 → V109, with V108 unmentioned. End state: V108 has no entry in the migration changelog block.

Pre-existing — introduced by #512, not this PR — but this PR is the natural place to backfill since it touched the same docstring. Recommend a follow-up commit (or amendment to a future PR) adding a `### V108 - position columns for entity / catalogue / item lists` section between V107 and V109.

**Where:** `lib/phoenix_kit/migrations/postgres.ex:529-540`

### NITPICK — `rename_role_permission/4` has unused `_prefix` arg

`v109.ex:75` takes `_prefix` but never uses it — the table name is already prefix-qualified at the call site. Either drop the parameter or use it (e.g., for a `SET search_path` statement). Cosmetic; the `_` prefix prevents the warning but the signature lies a little.

### NITPICK — V109 string-interpolated `DO $$` blocks

`v109.ex:60-91` interpolates `table`, `from_key`, `to_key` directly into the SQL `DO $$ … END $$` body rather than using parameters. All three are hardcoded constants in this migration (no user input), so there is no actual injection risk; flagging it only because it diverges from the safer pattern used elsewhere in the codebase. If `prefix` ever flowed in from external config and contained a quote, the construction would break — currently it can't, since `prefix_str/1` only accepts the three shapes (`nil`, `"public"`, atom-ish). Leave as-is unless a stylistic sweep happens.

### NITPICK — V109 `down/1` is one-way-lossy on new rows

`down/1` renames `customer_support_*` → `customer_service_*`, but a parent app that ran V109, then created *new* `customer_support_foo` settings the migration doesn't know about, would have those rows kept under the new key during a rollback (no harm, just orphaned). Standard rename-migration tradeoff; not worth complicating `down/1` for an emergency-only path. Calling it out for the record.

## What's good

- **Idempotent V109.** The `IF EXISTS (target) THEN DELETE source ELSE UPDATE source` pattern in `rename_setting/3` correctly handles re-runs and pre-seeded targets without unique-constraint violations. Same shape on `rename_role_permission/4`.
- **`Code.ensure_loaded?` guards preserved.** `integration.ex` keeps the dynamic guard around the renamed `PhoenixKitCustomerSupport.Web.UserList` so absent-package = no routes; consistent with how every other external module is wired.
- **Anonymizer fix.** `auth.ex:2687` had a pre-existing stale `Module.concat([PhoenixKit, Modules, Tickets, Ticket])` that's been a no-op since the original Tickets→CustomerService rename. The 57cb97f1 commit body acknowledges this and points it at the new external module — a real bug fix, not just a rename.
- **Test cleanup is honest.** `e2f51ca7` drops registry-specific assertions that no longer apply (the package is external, not a test dep) instead of mocking — preserves test integrity.
- **6360da54 reverts a self-bumped @version**, deferring to maintainer ownership of `mix.exs`/CHANGELOG. Matches the project's stated CHANGELOG ownership rule.

## Verified locally

- `git pull` clean fast-forward from `635a6cf1` → `54b976f3`.
- `mix compile --warnings-as-errors` — exit 0.
- `rg "customer.service|customer-service|CustomerService" lib/ --type elixir` — only hits in `migrations/postgres.ex` (history doc), `migrations/postgres/v77.ex`, `migrations/postgres/v109.ex`, `migrations/postgres/v35.ex`. Zero orphans in live code.

## Suggested next step

Bump `@version` 1.7.103 → 1.7.104 (hex `latest` is currently 1.7.103). CHANGELOG entry is the maintainer's call.
