# PhoenixKit 2.41.1 release review

Date: 2026-09-27

Scope: unreleased changes since v2.41.0, including PR #877, dependency
updates, and the pending image/render-cache changes.

## Findings and fixes

- **BUG - MEDIUM:** Nested `RenderCache.take/1` calls erased the enclosing
  render's failure mark and consumed nested failures. Preserve the outer
  state and propagate nested failures, including when rendering is interrupted.
  Added regression tests for nesting, exceptions, exits and throws.
- **BUG - MEDIUM:** `KnownPackages.clear_cache/0` could fail if the ETS owner
  exited between deletion calls. Clear the dedicated table in one operation,
  tolerate an absent table, and avoid creating a table owned by a cleanup
  process. Added an idempotent absent-cache regression test.
- **IMPROVEMENT - MEDIUM:** Development-only esbuild and Tailwind configuration
  produced missing-application warnings in tests and production. Scope it to
  development and remove the ineffective test overrides.
- Completed the 2.41.1 changelog with PR #877, the dependency updates and the
  review fixes. No schema changes were introduced.

## Validation

- `mix precommit` passed after the fixes, including all 240 JavaScript tests.
- The initial full database-backed run found the ETS cleanup race above;
  all 48 affected tests passed after its fix.
- Final full PostgreSQL-backed run: 71 doctests, 6,928 tests, zero failures,
  six skipped and one excluded (the test role lacks `CREATEROLE`).

## Integration contract

Caching renderers must wrap the full render in `RenderCache.take/1` and avoid
storing `{:retry, html}` results. Tracking is local to the calling process;
lookups performed in spawned tasks are not automatically propagated.
