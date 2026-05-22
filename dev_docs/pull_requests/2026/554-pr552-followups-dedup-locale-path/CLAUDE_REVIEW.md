# PR #554 — PR #552 follow-ups: dedup + 3 missed sites + 22 new tests

State: MERGED into `dev` (commit `5d0d4d74`).
Author: @mdon
Diff: +573 / -77 across 11 files (3 new, 8 modified).

## Scope recap

Four commits stacked on top of #552 + the boss's doctest follow-up
(`42722ff2`):

1. `b757ca01` — gates `process_valid_locale/2` 301 on `prefixless_primary?/0`
   (fix for the login regression), plus fixes the same
   `_is_default`-ignored bug in `sitemap/sources/{static,posts}.ex` already
   patched in the publishing source by #552.
2. `edf63d0f` — `redirect_invalid_locale/2` now swaps vs. strips per the
   setting so the cleaned URL matches the rest of the app's emission shape.
3. `97543a29` — extracts the shared locale-prefix decision into
   `PhoenixKit.Modules.Sitemap.LocalePath`; promotes `prefixless_primary?/0`
   to a public boot-safe wrapper on `Languages` so `Routes` + `Auth` share
   one rescue policy.
4. `fac2c665` — fills the two test gaps surfaced by the self-audit
   (canonical-redirect gate, Languages LV toggle handler).

I read the full diff against `dev` (`gh pr diff 554`) and walked
`process_valid_locale/2` + `redirect_invalid_locale/2` in the merged
file to confirm the final shape.

## Verdict

Ship as-is. The login-breaking gate fix is correct, the dedup is clean
and decision-only (each source keeps its own segment formatting), and the
two test files close the regressions the audit identified. Notes below
are nitpicks — nothing blocking.

---

## IMPROVEMENT - MEDIUM — `redirect_invalid_locale/2` calls `prefixless_primary?/0` twice

`lib/phoenix_kit_web/users/auth.ex:1987-1991` evaluates the gate twice
to derive `replacement_segment` and `replacement_suffix`. The wrapper
is cheap (Process.get + ETS-backed Settings read) but the two reads
can briefly disagree if a Languages toggle write lands between them.
Likelihood is negligible (this plug only fires on invalid-locale URLs),
so this is a code-smell more than a bug.

Suggested shape:

```elixir
{replacement_segment, replacement_suffix} =
  if prefixless_primary?(), do: {"/", ""}, else: {"/#{default_base}/", "/#{default_base}"}
```

Same logic, one read, easier to reason about.

## IMPROVEMENT - MEDIUM — `LocalePath` moduledoc says "three rules", lists four

`lib/modules/sitemap/locale_path.ex:9` — "Every sitemap source ... using
the same three rules:" then the numbered list runs 1–4. A reader hunting
for an off-by-one in the policy might assume one of the rules is meant
to be folded into another. Easy fix: change "three" → "four", or drop
the count entirely.

## NITPICK — `Languages.prefixless_primary_safe?/0` duplicates the `mix_task_context?/0` sentinel

`lib/modules/languages/languages.ex:42-46` reimplements
`PhoenixKit.Utils.Routes.mix_task_context?/0` rather than calling it.
The PR commit message acknowledges this is intentional ("settings-cache-
status sentinel is the same regardless of caller") but the comment on
the private function only restates the duplication. If `Routes` ever
adds another guard to `mix_task_context?/0` this copy will silently
drift. A `Languages.mix_task_context?/0 = Routes.mix_task_context?/0`
delegation would be safer, or move the sentinel to a neutral home
(e.g. `PhoenixKit.Config`).

## NITPICK — `auth_locale_test.exs` mixes setter styles in cleanup

The setup uses `Languages.set_default_language_no_prefix(true)` to
mutate the gate, but the `on_exit` calls
`Settings.update_boolean_setting("default_language_no_prefix", false)`
directly. Both work today because the setter is a thin wrapper on the
settings write, but the test asserts on `Languages.default_language_no_prefix?/0`
elsewhere — keeping the cleanup symmetric with the setter prevents a
future cache-invalidation bug from making the cleanup a no-op.

## NITPICK — `LocalePath.emit_prefix?/2` is named like a predicate but has a side rationale

The `nil` clause encodes "no language was supplied → don't emit", which
is correct for the call sites but isn't obvious from the function name.
The moduledoc rule 1 covers it; just calling out that future callers
who pass `nil` deliberately (as "use site default") will get the
opposite of what the name suggests. Worth a one-line comment on the
`nil` clause itself.

## What I checked and was happy with

- **The login regression fix.** `process_valid_locale/2:1846-1847` now
  gates the redirect on three conditions; both setting states traced
  through `validate_and_set_locale/2` arrive at the canonical shape
  without swallowing POST bodies. The four tests in
  `auth_locale_test.exs` cover all four branches of the truth table.
- **`redirect_invalid_locale/2` swap-vs-strip.** Walked the path
  `/phoenix_kit/xx` and `/phoenix_kit/xx/admin/users` through both
  setting states; the `String.ends_with?` branch + the `String.replace`
  branch compose correctly because the suffix and segment replacements
  share a setting read.
- **`LocalePath` extraction is decision-only.** The three sources still
  format the segment themselves (`get_display_code/2` for publishing,
  `DialectMapper.extract_base/1` for static/posts), so the hreflang-
  aware dialect emission on publishing isn't lost.
- **`LocalePath.single_language_mode?/0` rescue convention.** Defaults
  to `true` → `emit_prefix?/2` returns `false`. Matches the install-
  time behaviour where the sitemap module would otherwise emit broken
  multi-lang entries against a missing Settings row.
- **Tests are at the right level.** Policy in
  `test/integration/sitemap/locale_path_test.exs`, swap-vs-strip in
  `test/integration/users/auth_locale_test.exs`, toggle UX in
  `test/integration/phoenix_kit_web/live/modules/languages_toggle_test.exs`.
  No duplication; the sitemap sources delegate trivially so the policy
  test is the canonical coverage point (PR body says this explicitly).

## Open follow-up acknowledged by the PR

`@spec set_default_language_no_prefix/1` references
`PhoenixKit.Settings.Setting.t()` which lacks `@type t/0`. The PR body
notes this is being fixed separately (and commit `0b6ec6ff` on `main`
already added it). Not in scope for this PR.

## Out-of-scope observation surfaced by reviewing the diff

`Sources.Publishing.collect/1` still walks each group three times per
sitemap generation (see memory note `project_sitemap_publishing_traversal.md`).
Independent from #554's locale-prefix work; flagging here so it isn't
lost when the next sitemap PR lands.
