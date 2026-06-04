# PR #582 — Generalize AI translation: shared pipeline, glue, hint + quality

**Reviewer:** Claude
**Scope:** `Modules.AI.{Translatable,Translations,TranslateWorker}`, `Module`/`ModuleRegistry`
`ai_translatables/0`, `Components.AITranslate(.ex)` + `AITranslate.{FormGlue,FormBinding}`,
tests, `.dialyzer_ignore.exs`, plan/follow-up docs.

## Verdict

High-quality foundational refactor. The behaviour/adapter split is clean, the generic
worker's error handling is careful and well-reasoned, and the payload-minimal broadcast
scoping is a genuinely good security/privacy decision (and is tested). No correctness bugs
found that I can confirm. One item to verify against the `PhoenixKitAI` error contract, plus
a few nitpicks.

---

## IMPROVEMENT - MEDIUM (verify) — 429 is classified non-retryable

`translate_worker.ex` `retryable?/1` + test

Rate limiting is handled only via `{:error, {:ai_error, :rate_limited}}` → `{:snooze, 30}`.
`{:ai_error, {:api_error, 429}}` is deliberately **non-retryable** (the test pins
`refute retryable?({:ai_error, {:api_error, 429}})`), so a 429 surfaced as an `:api_error`
status (rather than the `:rate_limited` atom) is **discarded silently** — terminal failure,
no snooze, no retry.

`Translation.do_translate/6` passes the plugin's `reason` through verbatim
(`{:error, reason} -> {:error, {:ai_error, reason}}`), so which shape a 429 takes depends
entirely on `PhoenixKitAI`'s contract, which isn't in this repo. The author clearly intends
the plugin to emit `:rate_limited` for throttling — but if any provider/path ever returns a
bare HTTP 429 as `{:api_error, 429}`, that translation dies on first attempt.

Ask: confirm `PhoenixKitAI` always normalises 429 → `:rate_limited`. If not guaranteed,
treat `{:api_error, 429}` as snooze (or at least retryable) as defense in depth — it's the
canonical retry-after status.

**Status: left as-is, needs maintainer confirmation.** Flipping this would be
defense-in-depth against an error shape I can't verify (the plugin contract lives outside
this repo, and the non-retryable choice is intentional + pinned by a test). Not changed
unilaterally — confirm the `PhoenixKitAI` contract first.

---

## BUG - LOW — credo `--strict` fails on the new test — ✅ FIXED (c7ec90f1)

`translations_test.exs:90` called `PhoenixKit.PubSub.Manager.subscribe/1` fully-qualified,
tripping Credo's nested-module-alias check. With `--strict` this exits 2, so the merged
state fails the documented `mix precommit` / `mix quality.ci` bar. Fixed by aliasing
`PhoenixKit.PubSub.Manager, as: PubSubManager` and using the short form. `mix credo --strict`
now exits 0; `mix compile --warnings-as-errors` clean.

## NITPICK — `find_ai_translatable/1` rescans all modules per perform

`module_registry.ex` `find_ai_translatable/1` → `all_ai_translatables/0` folds over
`all_modules()` on every worker run. Fine at translation volumes, but it's pure recompute on
a path that could fan out (`enqueue_all_missing` = one job per language). If it ever gets
hot, memoize the map.

## NITPICK — app-level dedup is TOCTOU

`translations.ex` `job_in_flight?/1` does `exists?` then insert, so two concurrent enqueues
for the same `(type, uuid, target_lang)` can both pass and both insert a job. The moduledoc
explains *why* Oban's native `unique:` was dropped (the `:suspended` enum gap raising
`22P02`) and that this fails open — correctness is covered by the adapter's required atomic
merge, so the worst case is duplicate wasted work, not corruption. Acknowledged tradeoff;
noting for the record.

## NITPICK — fixed modal id

`ai_translate.ex` hardcodes `id="ai-translation-modal"`. Two translate modals on one page
would collide. Single-translatable-form-per-page is the implicit assumption (same shape as
MediaBrowser's single-browser assumption); worth a doc line if multi-form ever lands.

## Positives worth keeping

- **Payload-minimal broadcast scoping** (`Translations.broadcast/3`): the full payload with
  `:fields` goes only to the per-resource topic the form consumes; global + adapter topics
  get a content-free summary. Translated text never fans out to broad monitor/dashboard
  topics. Tested three ways.
- **Adapter-boundary hardening**: `safe_source_fields/1`, `safe_put_translation/2`,
  `adapter_topics/1`, `load_resource/2` all normalise crashes/bad shapes into `{:error, _}`
  so a misbehaving external adapter can't blow up the worker after `:translation_started`.
- **Retry/terminal discipline**: `{:snooze, 30}` on rate-limit doesn't consume an attempt;
  terminal `:translation_failed` is broadcast only when the job won't retry (no spinner
  flicker mid-retry); deterministic failures `:discard`.
- **Stall-timer correctness**: per-arm `make_ref()` token guards against a stale `:slow_tick`
  already in the mailbox when the clock is superseded (cancel can't un-send). The Translate
  button is `action_disabled?` while `has_in_flight?`, which also prevents the double-dispatch
  progress-skew I went looking for.
- **`Translatable` moduledoc** spells out the multi-job persist race and the two correct
  atomic-merge strategies — exactly the trap an adapter author would otherwise fall into.
- Whitelist-before-`String.to_existing_atom` in `select_ai_scope/2` and `first_enabled_scope/1`
  (no atom-table injection from client scope values).

## Tests

`translations_test` + `translate_worker_test` cover the right pure surfaces (set difference,
plugin-absent degradation, broadcast scoping, `retryable?/1`, setup-failure discard paths)
and correctly leave the live AI round-trip to consumer integration tests. `async: false`
rationale (shared global topic) is sound.
