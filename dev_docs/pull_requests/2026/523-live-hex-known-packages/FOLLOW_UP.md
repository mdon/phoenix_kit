# PR #523 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**NITPICK: `fetch_hex_page/3` recursion has no page-count cap.**
  Added an `@max_pages 20` module attribute and a `page_count`
  parameter to `fetch_hex_page/4` (`lib/phoenix_kit/known_packages.ex:151-176`).
  When the page counter exceeds `@max_pages`, recursion bails with a
  Logger.warning and returns whatever's been collected so far. A
  malformed `Link` header pointing back to the same page can no
  longer cause infinite recursion. 20 pages × 100/page = 2000
  packages — comfortable headroom for the `phoenix_kit_*` namespace
  even at long-term growth.~~

- ~~**NITPICK: `ensure_table/0` rescues `ArgumentError` to handle a
  race; comment would help.** Added a 3-line comment inside the
  `rescue` block (`lib/phoenix_kit/known_packages.ex:84-88`)
  explaining the race shape — two processes both seeing
  `:undefined` from `:ets.whereis/1` and both attempting `:ets.new/2`,
  the second one raising. The reader no longer has to derive the
  reason from "why would `:ets.new` raise an `ArgumentError`?"~~

- ~~**NITPICK: Logger.warning vs Logger.error split is correct but
  undocumented.** Added an "## Operational signals" section to the
  module's `@moduledoc` (`lib/phoenix_kit/known_packages.ex:25-41`)
  documenting the three log levels — `:warning` (stale-served +
  empty-cache-extras-only) vs `:error` (exceeded max stale age) —
  and what each signals operationally. Operators alerting on Hex
  outage patterns can now read the moduledoc to understand which
  level escalates.~~

## Skipped (deferred / out-of-scope)

- **IMPROVEMENT - MEDIUM: `not_installed_packages/0` is called from
  `mount/3`; cold-cache page load blocks on Hex for up to 3 seconds.**
  Significant Phoenix-thinking concern. Fixing it requires reshaping
  the modules LiveView to use `assign_async/3` for the
  not-installed-packages list, which is a substantive refactor
  (template skeleton state, `<.async_result>` wrapper, etc.). Worth
  doing soon but not a triage-sized change. Cold-deploy mitigation
  for now: the 10-min cache means only the first user per
  10-min window pays the latency.
- **NITPICK: PR body says `:persistent_term` (code uses ETS) and
  describes fields as "removed" (kept for back-compat).** PR-body
  drift; nothing actionable in repo.
- **IMPROVEMENT - LOW: `derive_module_atom/1` calls `String.to_atom`
  on Hex package names.** Atom-table growth bounded by the prefix
  filter (~20 packages today). Worth dropping the field entirely
  in a future PR since no in-repo caller reads it; out of scope here.
- **NITPICK: `parse_next_link/1` header lookup.** Already correct
  for `Req` (lowercase keys). Portability across HTTP clients is a
  hypothetical concern; current contract is sound.

## Open

None.
