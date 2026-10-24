# PhoenixKit 2.64.0 release recheck

**Reviewer:** GPT / Codex · **Date:** 2026-10-24

Rechecked recent PRs #963–#981 and their follow-up fixes, concentrating on session permissions, public storage URLs, provider checks and V223. Previous GPT reviews of #962, #965, #966, #968, #969 and #980 remain in their own directories. Also inspected the direct profile-settings-tab registration and viewer-country changes; their follow-up identity/permission and country-refresh corrections are present.

## Findings

- **BUG - MEDIUM (fixed):** a non-string UUID could crash `Storage.direct_urls/1` and lose valid entries. Both pair values now require strings; a mixed-invalid-input regression preserves the valid URL.
- **BUG - HIGH (release pairing):** V223 and the published AI module use different cost schemas. Current AI main already implements dollar costs, but its core floor was too low. Prepared the companion pin and dependency-test correction. Release notes require the compatible AI companion and describe the journal rewrite lock and legacy-account removal.
- **IMPROVEMENT - MEDIUM (fixed):** release notes omitted the session confirmation API/V222, module validators, batch direct URLs, grant retries, API tabs and delivery-based template usage. Added these to the 2.64.0 entry.

## Validation

- `mix precommit` passed: warnings-as-errors compilation, unused-dependency check, test-tree compilation, formatting, strict Credo, Dialyzer and all 473 JavaScript tests.
- Isolated PostgreSQL regression run: `direct_urls_test`, V223, V193 and the complete named-schema migration-chain test — 39 tests, 0 failures. The scratch database was created for this run and removed afterwards.
- Companion `phoenix_kit_ai`: full suite against local core — 1,977 tests, 0 failures, including a new revoked-session guard test.
- Initial `mix prerelease`: compilation, quality checks, both dependency audits, docs, package build, manifest hash and package contents passed; the expected dirty-tree check remains until the release commit. ExDoc emits existing documentation-reference warnings.
- `PGPOOL=12 mix test --max-cases 8`: 12,774 tests and 89 doctests, 0 failures, 21 skipped and 1 excluded. PostgreSQL was reachable; the excluded privilege test requires CREATEROLE, which this role lacks.
- Final clean-tree release gate pending the release commit.
