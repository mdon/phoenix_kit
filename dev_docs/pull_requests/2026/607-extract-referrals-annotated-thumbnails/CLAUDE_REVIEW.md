# PR #607: Extract referrals into a module + annotated media thumbnails

**Author**: @alexdont (Alexander Don)
**Reviewer**: @CLAUDE
**Status**: ✅ Merged (post-merge review)
**Commit**: `af7a12f4` (merge); reviewed as the net diff `abcfc049..fd4e5d18`
(two commits: `6e04a31e` annotated thumbnails, `fd4e5d18` referrals extraction)
**Date**: 2026-06-25

## Goal

Two unrelated concerns bundled in one PR:

1. **Referrals extracted to `phoenix_kit_referrals`.** The referral-codes feature
   leaves core (schemas, business logic, admin UI) and becomes a standalone,
   auto-discovered package — mirroring posts / user_connections. Core keeps the
   database tables (migrations untouched) and adds a runtime-dispatch facade,
   `PhoenixKit.Users.Referrals`, so the signup / OAuth / magic-link flows depend
   on referrals only at runtime, never at compile time.
2. **Annotated media thumbnails.** A file's Etcher annotation shapes are baked
   into a single deterministic `thumbnail_annotated` PNG variant (ImageMagick,
   geometry→draw via `Etcher.Raster` from etcher 0.7), regenerated in the
   background by a debounced Oban job, and preferred in the MediaBrowser grid.
   Gated behind a project setting (`storage_annotated_thumbnails_enabled`, off by
   default).

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/users/referrals.ex` | **New** runtime facade — resolves the installed referrals module by key (`ModuleRegistry.get_by_key("referrals")`) and dispatches via `apply/3`; degrades safely (disabled / `nil` / no-op) when absent |
| `lib/phoenix_kit/module_registry.ex` | Drop `PhoenixKit.Modules.Referrals` from `internal_modules/0`; doc example refreshed |
| `lib/phoenix_kit/dashboard/admin_tabs.ex` | Remove the hardcoded "Referral Codes" admin subtab |
| `lib/phoenix_kit_web/integration.ex` | Remove the hardcoded referrals route injection (`ReferralsRoutes`) — routes now flow through module discovery |
| `lib/phoenix_kit/users/{oauth,magic_link_registration}.ex`, `lib/phoenix_kit_web/users/{registration,magic_link_registration}.ex` | Swap alias `PhoenixKit.Modules.Referrals` → `PhoenixKit.Users.Referrals` |
| `lib/modules/referrals/**`, `lib/phoenix_kit_web/routes/referrals.ex` | **Deleted** (moved to the package) |
| `test/phoenix_kit/module_{registry_,}test.exs` | Drop Referrals from expectations; add the previously-missing `PhoenixKit.Notifications` so the internal-module list matches `internal_modules/0` exactly |
| `lib/modules/storage/services/annotation_thumbnail.ex` | **New** — bakes the `thumbnail_annotated` variant; gate, generate, remove, ImageMagick `convert` |
| `lib/modules/storage/workers/annotation_thumbnail_job.ex` | **New** debounced Oban worker (`queue: :file_processing`); version-robust unique states |
| `lib/modules/storage/services/variant_generator.ex` | **New** `store_prepared_variant/5` — stores an externally-rendered variant via the existing stats/bucket/instance/location tail |
| `lib/phoenix_kit_web/components/media_canvas_viewer.ex` | Enqueue a refresh whenever shapes are written/deleted |
| `lib/phoenix_kit_web/components/{media_browser.ex,core/media_thumbnail.ex}` | Grid prefers `thumbnail_annotated` (gated), with a checksum cache-bust |
| `lib/modules/storage/web/settings.{ex,html.heex}` | "Annotated Thumbnails" toggle in Media Configuration |
| `mix.exs`, `mix.lock` | Bump `:etcher` `~> 0.6.5` → `~> 0.7` (0.7.1) |

## Assessment

**Solid, well-reasoned PR — no correctness bugs found.** I verified the
load-bearing facts against core on both halves:

### Referrals extraction — verified ✅

- **The facade covers every call site.** The four signup-flow modules call only
  `get_config/0`, `get_code_by_string/1`, `expired?/1`, `usage_limit_reached?/1`,
  and `use_code/2` — every one is defined on `PhoenixKit.Users.Referrals`. No call
  site references a function the facade lacks. ✅
- **The disabled-config shape matches consumers.** Call sites read
  `config.enabled` / `config.required` with **dot access** (atom keys); the
  facade's `@disabled_config` is `%{enabled: false, required: false}` — both keys,
  atom-keyed — so the module-absent path doesn't `KeyError`. The installed path
  returns the package's `get_config/0` verbatim (which still carries
  `max_uses_per_code` / `max_codes_per_user` for the Modules-page card). ✅
- **`function_exported?` in `dispatch/2` works because the module is loaded.**
  `get_by_key/1` calls `safe_call(mod, :module_key, …)` on each candidate, which
  forces the BEAM to load it — so by the time `dispatch/2` reaches
  `function_exported?/3`, the resolved module is loaded and the check is reliable.
  `apply/3` keeps the package out of core's compile-time xref, as intended. ✅
- **No dangling hard references.** `rg` for `Modules.Referrals` / `ReferralsRoutes`
  in `lib/` + `test/` is clean apart from the facade + aliases. The remaining
  `"referral"` hits are all legitimately retained: the V04–V74 migrations (core
  owns the tables), the `auth.ex` fallback-redirect map and `admin_nav.ex` icon
  case (both generic, enabled-gated or string-keyed), shared `icons.ex` /
  `badge.ex` components, and a `module_card.ex` docstring example. ✅
- **Test/source drift fixed, not introduced.** `module_test.exs`'s
  `@all_internal_modules` now equals `internal_modules/0` exactly (adds the
  long-missing `Notifications`); `module_registry_test.exs` uses a subset
  assertion, so dropping Referrals from its `expected` is correct. ✅

### Annotated thumbnails — verified ✅

- **Queue is correct.** `queue: :file_processing` matches every other storage
  worker and the installer's `oban_config.ex` (`file_processing: 20`). Jobs will
  actually run. ✅
- **`store_prepared_variant/5` faithfully mirrors the existing pipeline.** It
  reuses the same private tail as the synchronous variant path
  (`get_variant_file_stats` → `store_variant_file` → `create_variant_instance` →
  `create_variant_file_locations`), including the identical `storage_info.bucket_ids`
  key — verified against the in-file caller at lines 121–134. ✅
- **The checksum cache-bust is safe.** The signed URL carries its token in the
  **path** (`/file/:file_uuid/:variant/:token`), and `file_controller.show/2`
  validates only `file_uuid + variant + token`. The appended `?v=<checksum>` lands
  in `query_params` and is ignored, so it busts the CDN/browser cache without
  breaking signature validation. ✅
- **Oban hygiene is right.** `perform/1` pattern-matches the **string** key
  `"file_uuid"` (JSON-serialized args); errors propagate as `{:error, reason}` for
  retry rather than being swallowed; `enqueue/1` is best-effort
  (`rescue _ -> :ok`) so it can't break the annotation-save path. The
  unique-states set is computed from the installed `Oban.Job.states/0` minus the
  terminal states — robust across 2.20/2.23, and excluding `:completed` is the
  correct fix for the "edit dropped until I draw again" throttle. ✅
- **Deterministic storage path = no variant accumulation.** The baked variant's
  storage path is keyed on the stable `file_checksum` + fixed variant name, so
  each regen overwrites the same bucket object; `remove_variant/1` clears the old
  `FileInstance` row first so a fresh checksum is recorded. ✅

Findings below are all **edge-case improvements**, not bugs. Given the PR ships a
clean, well-built feature, I made **no code changes on this release cut** — each
is documented with why a fix was deferred.

## Findings

### IMPROVEMENT - MEDIUM (not fixed) — Modules page can render the referrals card twice

Now that referrals is external, an installed `phoenix_kit_referrals` is
discovered by `ModuleDiscovery.discover_external_modules/0` and surfaces in the
generic external-modules loop (`modules.html.heex:721`,
`for ext <- @external_modules, ext.key in @accessible_modules`). But core **also**
still renders a *hardcoded* "Referral Codes" card (`modules.html.heex:74`, guarded
by `"referrals" in @accessible_modules`). With the package installed, both
conditions hold → **two referral cards** on `/admin/modules`.

This is **not unique to this PR** — `comments`, `connections`, and
`customer_support` are already external *and* keep hardcoded cards, so the same
latent duplication already exists for them; there is no key-exclusion in either
`load_external_modules/1` or the template loop. The PR simply moves referrals into
that same pattern.

**Why not fixed here:** the right fix is a *holistic* dedup decision the
maintainer should own — either drop the hardcoded cards for every external module
and rely on the (less rich) generic card, or have the external loop skip keys that
already have a bespoke card. Removing only the referrals card would be
inconsistent with comments/connections and could regress the richer stats UI.
Worth a follow-up sweep across all external-with-hardcoded-card modules.

### NITPICK - LOW (not fixed) — temp-file leaks on `AnnotationThumbnail.generate/1` error paths

In `generate/1`, the happy path cleans up both temps (`store_prepared_variant`
removes the rendered `output`; the function `File.rm`s `original_path`). On error
paths a temp can linger:

- `run_convert/3` failing → the `else` branch can't reach the `original_path`
  binding, so the retrieved original temp leaks.
- `store_prepared_variant/5` returning `{:error, _}` → it only calls
  `cleanup_temp_files/1` on success, so the rendered `output` PNG leaks.

Bounded to `System.tmp_dir!()` on rare failures (missing ImageMagick, bucket-store
error) that the OS reaps anyway. **Why not fixed:** a correct fix means
restructuring the `with`/`else` error handling (e.g. hoist `output` and wrap in
`try/after`, plus thread `original_path` cleanup) in newly-authored feature code —
more churn than the low-severity leak warrants on a release cut. Flagged for the
author to tidy.

### NITPICK - LOW (not fixed) — debounce trailing edge: an edit during render can be missed

`@unique_states` includes `:executing`, so an annotation edit made **while a regen
is mid-flight** dedups against the running job (no new job enqueued), and that job
already read the annotation set at the start of `perform/1`. The just-made edit
isn't reflected until the *next* edit enqueues a fresh job. The window is one
ImageMagick render (sub-second to a couple seconds), so it's rare and
self-healing. The chosen trade-off (include `:executing` → never overlap renders)
is reasonable; excluding it would favor freshness at the cost of concurrent
regens. Documented, not changed.

### NITPICK - LOW (not fixed) — stale baked variants persist after the feature is disabled

Toggling `storage_annotated_thumbnails_enabled` off only writes the setting; it
does **not** sweep existing `thumbnail_annotated` rows. The grid is safe — 
`generate_urls_from_instances/4` rejects the variant when disabled — but the DB
rows (and bucket objects) linger until each file's next annotation edit triggers a
(now-disabled) refresh that removes them. Any future non-grid consumer of
`MediaThumbnail.resolve_url/2` that doesn't apply the same gate would surface them.
Cosmetic / cleanup only; off-by-default makes it low-exposure. Not changed.

### OBSERVATION (pre-existing) — `Code.ensure_loaded?(Referrals)` guards are now always true

In `users/oauth.ex` and `users/magic_link_registration.ex`,
`maybe_process_referral_code/2` / `process_referral_code/2` still guard with
`if Code.ensure_loaded?(Referrals)`. Since `Referrals` now aliases the core facade
(always compiled), the guard is always true — but it was *also* always true
before (the old `PhoenixKit.Modules.Referrals` was a core module). The facade's
own degrade-to-`nil`/no-op behavior makes the guard redundant rather than wrong.
Harmless; could be dropped in a later cleanup.

## Verdict

Approve as-is for release. No bugs; the findings are deferrable edge-case
improvements, each documented above with rationale. Released as **1.7.166**.
