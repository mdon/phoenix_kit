# AI Translation Generalization

**Status:** in progress (Phase 1 additive core + catalogue). Authored 2026-06-02.

## Problem

`PhoenixKit.Modules.AI.Translation` already centralizes the *engine*
(`translate_fields/6` + structured-response parsing). But every consumer
re-implements the same orchestration on top of it:

- A `Translations` context (availability checks, list endpoints/prompts,
  settings-key resolution, default-prompt generation, `enqueue/1`,
  `enqueue_all_missing/2`, param validation).
- An Oban worker (load resource → build field map → `translate_fields` →
  persist to a `translations` JSONB → broadcast → activity log → retry
  classification → uniqueness).
- Form glue (in-flight state, dispatch, PubSub handling) + UI.

`phoenix_kit_projects` and `phoenix_kit_publishing` each carry ~1000 lines
of this, with slight behavioral drift. Adding `phoenix_kit_catalogue`
would be a third copy. This plan hoists the orchestration into core so a
consumer needs only a small **adapter** + a UI call.

## What already lives in core (do not duplicate)

- `PhoenixKit.Modules.AI.Translation.translate_fields/6` — the AI call +
  `---FIELD---` parse. Returns `{:ok, %{field => text}}` / `{:error, _}`.
- `PhoenixKit.Modules.AI.available?/0` — plugin loaded?
- `PhoenixKitWeb.Components.Core.LanguageSwitcher` `ai_translate` attr —
  the per-language sparkle + "translate all missing" UI primitive.
  (`multilang_tabs` does NOT forward it yet — Phase 2.)

## Design — additive core (Phase 1)

### 1. `PhoenixKit.Modules.AI.Translatable` (behaviour)

The only per-module code. A consumer implements one adapter module:

```elixir
@callback fetch(resource_type :: String.t(), uuid :: String.t()) ::
            {:ok, struct()} | {:error, term()}
@callback source_fields(resource :: struct(), source_lang :: String.t()) ::
            %{optional(String.t()) => String.t()}
@callback put_translation(resource :: struct(), target_lang :: String.t(),
            fields :: %{optional(String.t()) => String.t()}, opts :: keyword()) ::
            {:ok, struct()} | {:error, term()}
@callback pubsub_topics(resource :: struct()) :: [binary()]   # optional
@optional_callbacks pubsub_topics: 1
```

### 2. Discovery (`PhoenixKit.ModuleRegistry`)

A module declares an optional `ai_translatables/0` callback returning
`[{resource_type :: String.t(), adapter_module}]` (same discovery shape as
`notification_types/0` / `admin_tabs/0`). `ModuleRegistry.all_ai_translatables/0`
scans `all_modules()` and folds into `%{resource_type => adapter}`.
`find_ai_translatable/1` resolves one. **`resource_type` strings must be
globally unique** (namespace them: `"catalogue"`, `"catalogue_category"`,
`"catalogue_item"`, `"project"`, `"post"`, …).

### 3. `PhoenixKit.Modules.AI.TranslateWorker` (generic Oban worker)

`queue: :default`, `max_attempts: 3`, unique per
`(resource_type, resource_uuid, target_lang)` with `period: :infinity`
over all incomplete states. `perform/1`:

1. Resolve adapter from `resource_type` (discard if unknown).
2. `adapter.fetch/2` → resource (discard if not found).
3. `adapter.source_fields/2` → field map (empty ⇒ broadcast completed-empty, `:ok`).
4. `Translation.translate_fields/6`.
5. `adapter.put_translation/4` (adapter owns atomic/merge write).
6. Broadcast `{:ai_translation, event, payload}` on the core topic +
   `adapter.pubsub_topics/1`; one `ai.translation_added` activity entry.
7. Retry only transient AI errors (timeout/rate-limit/5xx); discard
   deterministic ones (parse, missing plugin/endpoint/prompt, persist).

Broadcast events: `:translation_started | :translation_completed | :translation_failed`.
Completed payload carries `fields` (the translated map) so a host LV can
patch its live changeset without a DB re-read.

### 4. `PhoenixKit.Modules.AI.Translation` orchestration additions

- `available?/0` — `AI.available?` AND ≥1 enabled endpoint.
- `list_endpoints/0`, `list_prompts/0` — `[{uuid, name}]`, guarded.
- `default_endpoint_uuid/0` — setting `ai_translation_endpoint_uuid`, else
  first enabled endpoint.
- `default_prompt_uuid/0` — setting `ai_translation_prompt_uuid`, else the
  shared `ai-translate-content` prompt by slug.
- `ensure_default_prompt/0` — idempotently create the shared prompt.
- `enqueue/1`, `enqueue_all_missing/2` — validate + insert `TranslateWorker`.
- `topic/0`, `topic/2`, `subscribe/2`, `missing_languages/3` — PubSub +
  helper for a host to compute missing langs.

The bespoke per-resource Settings keys (`projects_translation_*`,
`publishing_*`) collapse to one shared pair; a consumer may still override
per-call by passing explicit `endpoint_uuid`/`prompt_uuid`.

## Design — core UI (Phase 2)

- `multilang_tabs` forwards an `ai_translate` map to its internal
  `language_switcher`.
- A `use PhoenixKitWeb.AITranslate.Embed` macro injects the
  `handle_event("ai_translate", …)` + `handle_info({:ai_translation, …})`
  glue via `attach_hook` (same shape as `MediaBrowser.Embed`), so a form
  is `use` + `<.multilang_tabs ai_translate={...}>`.

## Consumers

- **catalogue (Phase 1, this pass):** optional `:phoenix_kit_ai` dep +
  `PhoenixKitCatalogue.AITranslatable` adapter (resource types
  `catalogue` / `catalogue_category` / `catalogue_item`, fields
  `name` + `description`, stored in `data["translations"][lang]`) +
  `ai_translatables/0` registration + a minimal "Translate missing with
  AI" affordance on the three form LVs. Greenfield — browser-verifiable.
- **projects / publishing (Phase 3, deferred):** refactor onto the core
  API, deleting their bespoke `Translations` context + worker. Gated on
  their full test suites staying green. **Requires a core release + Hex
  pin bump (boss-only), so it lands after core ships.**

## Hardening follow-ups (6-AI quorum, 2026-06-02)

A full quorum (Codex, Gemini, Kimi, Vibe, ZAI, M2) **unanimously validated
the one-Oban-job-per-target-language fan-out** as the right default (all
rejected a single 40-language call as fragile/all-or-nothing, and the
sequential single job for UX/timeout reasons). Applied + outstanding:

- **DONE — snooze on rate-limit.** `{:ai_error, :rate_limited}` →
  `{:snooze, 30}` in `TranslateWorker` instead of consuming a retry, so a
  burst drains rather than exhausting `max_attempts`. Works on any host.
- **TODO (quorum's #1, unanimous) — dedicated capped Oban queue.** The
  worker currently runs on `:default` (no per-resource cap → a ~40-call
  burst can trip provider 429s). Move it to a dedicated `ai_translation`
  queue with a small `limit` (panel range 3–8), wired into the host via
  `mix phoenix_kit.install/.update` (mirror `Install.ObanConfig` for the
  `catalogue_pdf` queue) + a queue-availability guard like the catalogue
  PDF worker, so jobs fail-visible instead of silently sitting when the
  queue is absent. Deferred deliberately: half-wiring it (worker off
  `:default` without the host config) would stop jobs running, and it
  belongs with the install-task/release work.
- **OPTIONAL (later, if cost dominates) — small language batches** (2–5
  langs per AI call): cuts repeated input tokens, but Kimi dissents
  (breaks granular retry, no call-count saving). Not the default.
- **OPTIONAL — staggered enqueue** (`schedule_in` offsets) as a softer
  burst cap where a dedicated queue isn't available.

Dedup mechanism: app-level query (4 always-present states) is intentional
over Oban `unique:` — `unique:` with an explicit 4-state list avoids the
runtime `22P02` but emits a compile warning that fails core's
`--warnings-as-errors`; same trade-off the catalogue PDF worker made.

## Release / sequencing

Core changes are boss-only to release. In `phoenix_kit_parent` (local
path deps) the whole tree compiles + runs, so Phase 1 is end-to-end
verifiable now. Hex pin bumps for catalogue/projects/publishing are a
follow-up the boss handles on the next core release.
