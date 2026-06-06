# PR #582 — Generalize AI translation: shared pipeline, glue, hint + quality

**Reviewer:** Claude
**Scope:** `Modules.AI.{Translatable,Translations,TranslateWorker}`, `Module`/`ModuleRegistry`
`ai_translatables/0`, `Components.AITranslate(.ex)` + `AITranslate.{FormGlue,FormBinding}`,
tests, `.dialyzer_ignore.exs`, plan/follow-up docs.

## Verdict

High-quality foundational refactor. The behaviour/adapter split is clean, the generic
worker's error handling is careful and well-reasoned, and the payload-minimal broadcast
scoping is a genuinely good security/privacy decision (and is tested). No correctness bugs
found that I can confirm. The one open item from the original pass (429 retry classification)
was verified against the real `PhoenixKitAI` contract and hardened — see the
**Follow-up (2026-06-05)** section below. The rest are nitpicks, some left for the developer.

---

## IMPROVEMENT - MEDIUM — 429 retry classification — ✅ RESOLVED + FIXED (2026-06-05)

`translate_worker.ex` `retryable?/1` + test

Original concern: `{:ai_error, {:api_error, 429}}` was **non-retryable** (the test pinned
`refute retryable?({:ai_error, {:api_error, 429}})`), so a 429 surfaced as an `:api_error`
status (rather than the `:rate_limited` atom) would be **discarded silently** on first
attempt. Whether that ever happens depends on the `PhoenixKitAI` error contract, which the
first pass couldn't see.

**Contract verified** against `/workspace/phoenix_kit_ai`. Translation runs
`ask_with_prompt → complete → Completion.chat_completion → handle_error_status/2`:

```elixir
def handle_error_status(429, _body), do: {:error, :rate_limited}        # → {:snooze, 30} ✓
def handle_error_status(402, _body), do: {:error, :insufficient_credits} # → discard ✓
def handle_error_status(status, body), do: {:error, {:api_error, status}} # 5xx → retryable ✓
# transport timeout → {:error, :request_timeout} → retryable ✓
```

So the **built-in OpenRouter client always maps 429 → `:rate_limited`** (snoozed before
`retryable?/1` is even consulted). `{:api_error, 429}` can only arise from a hypothetical
non-conforming *custom/future* provider — the shipped path was never at risk.

**Fix applied** (defense-in-depth for custom providers): added
`def retryable?({:ai_error, {:api_error, 429}}), do: true` — 429 is the canonical
retry-after, so a bare-429 from a custom client now retries with backoff instead of dying on
first attempt. Test updated (`refute` → `assert` for 429; added a `404` refute to keep the
"other 4xx don't retry" assertion). `mix compile --warnings-as-errors` + `mix credo --strict`
clean.

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

## Follow-up review (2026-06-05)

Second pass at the maintainer's request. The full pipeline + the `PhoenixKitAI` contract were
re-read end to end. No new correctness bugs. One fix applied (the 429 hardening above), plus
a doc-accuracy fix; the remaining items are **left for the developer** as low-priority.

### ✅ FIXED — misleading `retryable?` timeout comment

`translate_worker.ex` `retryable?({:ai_error, :timeout})`

The comment claimed the HTTP client "surfaces a request timeout as `:timeout`
(`{:error, :timeout} → {:ai_error, :timeout}`)". In reality `Completion.chat_completion/3`
remaps a transport timeout to `:request_timeout` **before** it reaches the worker, so the
`:timeout` clause never matches via the built-in client (the `:request_timeout` clause above
it does). Rewrote the comment to describe `:timeout` for what it actually is: a defensive
fallback for a provider/path that surfaces the raw atom. No behaviour change.

### ⬜ FOR DEVELOPER — fixed modal `id` (was a NITPICK; still open)

`ai_translate.ex:105` hardcodes `id="ai-translation-modal"`. Two AI-translate modals on one
page collide. Left as-is because it's guarded by the documented single-translatable-form-
per-page assumption (same shape as MediaBrowser's single-browser assumption) and a proper fix
threads an `id` through both the config map (`FormGlue.ai_translate_config/1`) and the
component — more surface than this follow-up warrants. **Wire a configurable `id` if/when a
second translatable form ever shares a page.**

### ⬜ FOR DEVELOPER — `find_ai_translatable/1` recomputes per `perform`

`module_registry.ex:236` → `all_ai_translatables/0` folds over every registered module on
every worker run; `enqueue_all_missing` fans out one job per language. Pure recompute, fine at
translation volumes. **Memoize in `:persistent_term` only if it ever shows up hot** (it
won't at current scale — deliberately left unoptimized).

### ⬜ FOR DEVELOPER (acknowledged, no action) — unprefixed dedup query

`translations.ex:360` queries `from(j in "oban_jobs", …)` — won't see jobs if Oban runs under
a non-public schema prefix, and the `exists?`-then-`insert` is TOCTOU. Both are **deliberate,
documented tradeoffs** matching the catalogue PDF worker (the moduledoc explains the dropped
`:suspended` enum that made Oban's native `unique:` unusable). Worst case is duplicate work,
not corruption, because `put_translation/4` is required atomic+merge-safe. Noted for the
record; no change recommended.

---

## PR #583 — V129: subscription_type_uuid column — ✅ NO ISSUES

Reviewed alongside #582. Correct and well-built:

- **Auto-dispatched**: the runner resolves `Module.concat([…Postgres, "V129"])`, so no manual
  registration list is needed — the new module is picked up by version number.
- **FK target exists in core**: `phoenix_kit_subscription_types(uuid)` is created/renamed by
  V65/V73/V74, so the FK resolves on a fresh build (not gated on the billing package).
- **Marker handling correct**: the hardcoded `COMMENT … IS '129'` is overwritten to `130` by
  the later V130 that runs after it in the same `ensure_current/2` sweep.
- **Idempotent**: every step is guarded (`information_schema` / `pg_indexes` existence checks),
  `down/1` reverses cleanly and resets the marker to 128.

Micro-note (not a defect, no action): on the legacy DBs the moduledoc describes (column
acquired via a historic `plan_uuid` rename), the guards key off the *specific* constraint/
index names — a legacy FK under a different name wouldn't be detected, so a second FK could be
added. Extremely low risk and outside the stated scope of the fix.

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
