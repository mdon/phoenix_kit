# PR #558 — Reject empty `fields` map in `Translation.translate_fields/6`

State: MERGED into `dev`.
Author: @mdon
Diff: +23 / -1 across 2 files (`lib/modules/ai/translation.ex`, `test/phoenix_kit/modules/ai/translation_test.exs`).

## Scope recap

Follow-up to PR #557, closing the last open NITPICK from its `CLAUDE_REVIEW.md`
("empty `fields` map dispatches a wasted AI request") that #557 left as the
author's call.

`translate_fields/6` previously accepted `fields = %{}` (the function-head guard
is only `is_map/1`, and `validate_unique_markers([])` passes), then rendered a
prompt with no field variables, called `PhoenixKitAI.ask_with_prompt/4` — real
token spend — and only failed afterward in `parse_response/2` with
`{:parse_error, :no_markers}`.

This adds a `validate_non_empty/1` guard to the `with` chain (after the uuid
checks, before `validate_unique_markers/1`) that rejects an empty map up front
with the same `{:error, {:parse_error, :no_markers}}` sentinel.

I read the full `translate_fields/6` chain, the new guard, and the downstream
`parse_response/2` it mirrors.

## Verdict

**Approve.** Clean, correct, well-scoped, well-documented. No blocking issues,
no behavior regression — strictly removes a wasted AI request (and its
`core.ai_translation.requested` audit entry) on a caller-bug path. One
non-blocking NITPICK on error *category*, and it's an intentional, documented
trade-off.

---

## Correctness — the sentinel equivalence holds exactly

The comment claims the new guard returns the same sentinel the old downstream
path produced. Traced and confirmed:

- Empty `fields` → (old path) `do_translate/6` → `parse_response(response, [])`
  → `upcased = []` → `parsed = %{}` → `map_size(parsed) == 0`
  → `{:error, {:parse_error, :no_markers}}` (`translation.ex:270`).

So callers see the **identical** result tuple as before — just without the
plugin call, the token spend, and the `log_request/4` audit write. No legitimate
caller ever got `{:ok, %{}}` from an empty map (it always errored), so there's
no behavior regression; the fix only shortens the path to the same error.

## Elixir-idiom check

- `defp validate_non_empty(fields) when map_size(fields) == 0` is the correct
  empty-map test — not `%{}`, which matches *any* map. ✔
- Function-head pattern matching over an in-body `if`/`case`. ✔
- Slots into the `with` chain; a non-`:ok` return short-circuits and the tuple
  conforms to `@type translation_result`. ✔
- The `is_map(fields)` head guard makes the two clauses exhaustive — no
  credo/dialyzer concern. ✔

## Placement

After the uuid validations, before `validate_unique_markers/1`. Sound:
`validate_unique_markers([])` would pass on its own, so the cheaper, clearer
emptiness rejection belongs first. The updated order comment in the test
(`endpoint → prompt → non-empty → unique-markers → plugin-available`) matches the
actual chain.

## Test

`"empty fields map → :no_markers (rejected before plugin call)"` asserts the
sentinel through the public `translate_fields/6` API rather than poking
internals — the right level. It relies on the same "PhoenixKitAI not loaded in
core CI" assumption already established by the sibling argument-validation tests
in the describe block.

---

## NITPICK — empty input classified as `:parse_error` (intentional, documented)

`{:parse_error, :no_markers}` describes a *parse* failure, but an empty `fields`
map is really an *input-shape* problem — sibling to `:no_endpoint` /
`:missing_prompt`, which are their own atoms. So the new guard files an
input-validation error under the parse-error category.

This is a deliberate, documented choice (the inline comment and PR body both
call it out): reusing the downstream sentinel means a caller that already
handles `{:parse_error, :no_markers}` from the partial-response path catches the
empty-input path with the same clause, with no new error class to branch on.
Given the result is byte-for-byte what the old path returned, preserving caller
error handling outweighs taxonomic purity here. Leave as-is.

---

## Positives

- Behavior-preserving by construction: the guard returns precisely the sentinel
  the old downstream path emitted, so the change is invisible to callers except
  for the eliminated token spend.
- Correct empty-map idiom (`map_size/1` guard), exhaustive clauses, clean `with`
  integration.
- Thorough inline comment explaining *why* the short-circuit exists and why the
  sentinel is reused — future readers won't mistake it for an arbitrary choice.
- Test exercises the public API and the validation-order comment was updated in
  lockstep, so the doc doesn't go stale.
