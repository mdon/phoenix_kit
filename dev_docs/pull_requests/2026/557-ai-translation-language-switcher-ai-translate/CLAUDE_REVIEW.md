# PR #557 — `PhoenixKit.Modules.AI.Translation` + language-switcher `ai_translate` attr

State: MERGED into `dev` (merge commit `bc102064`).
Author: @mdon
Diff: +965 / -4 across 5 files (2 new, 3 modified).

## Scope recap

First of three PRs for AI-driven translation. Adds:

- `PhoenixKit.Modules.AI` (`lib/modules/ai/ai.ex`) — `available?/0` loadability check for the optional `PhoenixKitAI` plugin.
- `PhoenixKit.Modules.AI.Translation` (`lib/modules/ai/translation.ex`) — `translate_fields/6` orchestration + public `parse_response/2` for the `---FIELD---` structured shape, with thorough error normalization and a `core.ai_translation.requested` activity entry.
- `ai_translate` map attr on `language_switcher_dropdown` — per-missing-language ✨ button + bulk CTA, pure event-emit (no `PhoenixKitAI` references).

I read both new modules in full plus the `language_switcher.ex` and test diffs.

## Verdict

Strong PR — well-documented, defensively coded, and well-tested (17 + 9 cases).
Error normalization (`try/rescue` + `catch :exit/:throw`), atom-or-string key
handling, and the dead-UI event gating are all done right. No blocking issues.
The notes below are documentation/contract mismatches and minor robustness
nits, not bugs in the happy path.

---

## BUG - HIGH — dialyzer fails on `PhoenixKitAI.ask_with_prompt/4` → `quality.ci` red on `dev`

`translation.ex:188` calls `PhoenixKitAI.ask_with_prompt/4`, an optional plugin
module. The PR added `@compile {:no_warn_undefined, [{PhoenixKitAI, :ask_with_prompt, 4}]}`
which silences the **compiler** warning — but not **dialyzer**, which `mix
quality.ci` (and therefore `mix precommit`) runs. Dialyzer reports:

```
lib/modules/ai/translation.ex:188:25:unknown_function
Function PhoenixKitAI.ask_with_prompt/4 does not exist.
Halting VM with exit status 2
```

This is the one un-skipped error (Total 162 / Skipped 161), so the gate exits 2.
The repo's established pattern for optional-plugin calls is a
`{"path", :unknown_function}` entry in `.dialyzer_ignore.exs` (see
`lib/modules/sitemap/sources/publishing.ex` and `lib/phoenix_kit_web/integration.ex`,
which guard `PhoenixKitPublishing` / `phoenix_kit_ecommerce` the same way). #557
added the compile no-warn but missed the dialyzer ignore, so CI's `quality.ci`
job has been red on `dev` since the merge.

**Fixed in follow-up:** added
`{"lib/modules/ai/translation.ex", :unknown_function}` to `.dialyzer_ignore.exs`.

## IMPROVEMENT - MEDIUM — documented `completed` key does nothing (misleading public API)

The `ai_translate` attr doc (`language_switcher.ex:147`) lists
`completed: ["fr"] # transient checkmark` in the shape and the prose says the
host broadcasts "`:in_flight` / `:completed` state back via PubSub." But the
component never reads `completed`: `ai_translate_show?/2` keys off `missing`,
`in_flight?/2` off `in_flight`, and nothing renders a checkmark for `completed`.
The test `"completed languages (no longer in missing) get no sparkle even with
stale state"` actually confirms `completed` is ignored by design.

So a host passing `completed: ["fr"]` and expecting a transient checkmark gets
nothing. Either implement the checkmark (and a render branch for it) or remove
`completed` from the documented shape and the "transient checkmark" comment.
For a public component attr, the doc promising a feature that isn't there is the
kind of thing that costs a consumer an afternoon. Recommend trimming the doc
now since sibling PRs will build against this contract.

## NITPICK — bulk-handler doc example re-enqueues in-flight jobs

The attr doc's example handler (`language_switcher.ex:170`) says, for the
`"*"` sentinel: `# enqueue one job per language in missing`. But the bulk
button's count uses `actionable_missing/1` = `missing -- in_flight`
(`:497`), explicitly so a click "doesn't redundantly re-enqueue jobs the host
already has in flight." A host that follows the documented example verbatim
will re-enqueue the in-flight languages anyway — defeating the subtraction.
Align the example comment to "enqueue one job per *actionable* language
(missing minus in_flight)."

## NITPICK — "case-insensitive marker matching" claim vs. case-sensitive regex

The moduledoc (`translation.ex:224-226`) and PR body say markers are matched
case-insensitively. In practice `marker/1` upcases the *field name* to build the
marker, and `extract_section/3` matches it with a regex that has only the `/s`
flag — no `/i`. So matching is case-insensitive on the field-name side, but the
*response* markers must be uppercase: a model emitting `---title---` won't
parse. Prompt templates ship uppercase markers so this is fine in practice, but
either add the `i` flag (cheap robustness against a sloppy model) or tighten the
wording to "field names are normalized to uppercase markers."

## NITPICK — empty `fields` map dispatches a wasted AI request

`translate_fields/6` accepts `fields = %{}` (guard is only `is_map/1`;
`validate_unique_markers([])` passes). It then renders a prompt with no field
variables, calls `PhoenixKitAI.ask_with_prompt/4` (real token spend), and only
fails afterward in `parse_response/2` with `{:parse_error, :no_markers}`.
Cheap to short-circuit: reject an empty `fields` map up front (alongside the
uuid validations) so a caller bug doesn't burn a request.

## NITPICK (i18n) — new strings hardcoded in English

"Translate all missing (N)", `aria-label`/`title` "Translate with AI" /
"Translation in progress" are hardcoded (`language_switcher.ex:388-470`). This
is *consistent* with the existing component (which already hardcodes
`placeholder="Search languages…"`), so it's not a regression — `language_switcher.ex`
isn't gettext-wired at all. But given this is literally the translation UI in an
i18n-first library, a future gettext sweep of the whole component (existing +
new strings) would be worthwhile. Not blocking for this PR.

---

## Positives

- Error normalization is exemplary: `try/rescue` + `catch :exit, :throw`
  guarantees every plugin failure mode (including `GenServer.call` timeout
  exits the moduledoc explicitly calls out) surfaces as `{:error, {:ai_error, _}}`.
- Validation-before-availability ordering is deliberate and tested, so the input
  contract is unit-testable without the optional plugin loaded.
- `@compile {:no_warn_undefined, [{PhoenixKitAI, :ask_with_prompt, 4}]}` is
  correctly narrowed to the single MFA, so typos in any other `PhoenixKitAI`
  call still warn.
- Duplicate-marker and missing-field rejection prevent silent half-translations
  — the right call for a persistence-feeding helper.
- Switcher component is cleanly pure-emit with atom-or-string key support and
  whitespace-trimmed event-name gating that hides dead clickable UI.
- 17 translation tests + 9 switcher tests; `parse_response/2` made public
  specifically for testability.
