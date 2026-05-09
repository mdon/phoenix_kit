# PR #518 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**NITPICK: Untracked 0-byte `lib/phoenix_kit_web/controllers/pages_html.ex`
  in working tree.** Deleted. The PR's #559f86df commit removed the
  module from the repo; a stray editor-recreated file at the same
  path was lingering uncommitted. Removed in this triage.~~

## Skipped (deferred / out-of-scope)

- **NITPICK: `auth.ex:998` `{"db", "/admin/db"}` priority list.**
  Acknowledged as intentional ("same shape as the also-external
  `phoenix_kit_ai` entry") — keeps redirect priority for hosts that
  later install `phoenix_kit_db`. Auto-discovery refactor of the
  entire `@admin_path_priority` list is a larger follow-up, not
  triage-sized.
- **NITPICK: Test count assertions remain hardcoded (`>= 7`).**
  The aspirational `>= length(@all_internal_modules)` would couple
  the `@all_internal_modules` constant in `module_test.exs` to
  `module_registry_test.exs`, which is two-file coupling for one
  number. Cosmetic. Worth fixing in a future test-cleanup sweep.
- **NITPICK: V107 test failures are pre-existing on `dev`.** Not in
  scope for #518's review surface — separate ticket.
- **NITPICK: `module-system-guide.md` reflow ordering convention.**
  Documentation note — could state the "small → medium → large"
  ordering explicitly above the table. Cosmetic.

## Open

None.
