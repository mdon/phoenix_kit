# PR #585 Review — Host-wiring docs, AITranslate.Embed macro, media-detail Leaf fix, V131 migration

**Scope reviewed:** 4 commits by Max Don, merged as `ca6e8bd2`.

| Commit | Description |
|--------|-------------|
| `42d45d58` | Add `AITranslate.Embed` macro for host wiring |
| `a9b1e1d0` | Document required host wiring on callback-message components |
| `f4157ee1` | Add V131 migration: `metadata JSONB` on staff people |
| `4d02510f` | Fix media detail comments: forward Leaf editor events to CommentsComponent |

**Files changed (7, +240/-12):**

| File | Nature |
|------|--------|
| `lib/phoenix_kit_web/components/ai_translate/embed.ex` | New — 117 lines, Embed macro |
| `lib/phoenix_kit_web/live/users/media_detail.ex` | `handle_info` additions for Leaf + catch-all |
| `lib/phoenix_kit_web/components/core/markdown_editor.ex` | Docs only (moduledoc) |
| `lib/phoenix_kit_web/components/media_gallery.ex` | Docs only (moduledoc) |
| `lib/phoenix_kit_web/live/components/media_selector_modal.ex` | Docs only (moduledoc) |
| `lib/phoenix_kit/migrations/postgres/v131.ex` | New migration |
| `lib/phoenix_kit/migrations/postgres.ex` | Version bump + docblock |

---

## 1. `AITranslate.Embed` (new — `embed.ex`)

### Summary

Introduces a `use` macro that injects `on_mount` lifecycle hooks to wire six `handle_event` clauses and one `handle_info` clause that every consumer of `FormGlue` was previously hand-duplicating. Uses `Phoenix.LiveView.attach_hook/4` to compose cleanly with host handlers without clause-ordering conflicts.

### Pattern Analysis

Consistency with existing embed macros:

| Aspect | `MediaBrowser.Embed` | `AITranslate.Embed` | `PhoenixKitComments.Embed` |
|--------|---------------------|---------------------|---------------------------|
| Hook mechanism | `@before_compile` + `on_mount` | `on_mount` only | `on_mount` only |
| Handler injection | Injected `def` clauses | `attach_hook` lifecycle hooks | `attach_hook` lifecycle hooks |
| Composition | Module def ordering wins | `{:cont, socket}` passthrough | `{:cont, socket}` passthrough |

**Assessment:** `AITranslate.Embed` correctly uses the lifecycle-hook-only pattern, which is cleaner than `@before_compile` injection. This avoids compiler-ordering subtleties and works regardless of how many Embed macros a host stacks. The pattern mirrors `PhoenixKitComments.Embed` and the url_sync path of `MediaBrowser.Embed`.

### Implementation Quality

**Event routing (6 `handle_event` clauses):**
- Each clause matches exact event name
- Each delegates to corresponding `FormGlue` public function  
- Each returns `{:halt, socket}` — correct for owned events
- Catch-all returns `{:cont, socket}` — ensures non-AI events pass through

**`handle_info` clause:**
- Matches `{:ai_translation, event, payload}` pattern
- Delegates to `FormGlue.handle_ai_translation_event/4` with `&resync_form/2` callback
- Catch-all returns `{:cont, socket}`

**`resync_form/2` override mechanism:**
- Runtime check with `is_atom(view)` guard — prevents crash if `socket.view` is nil
- Default assigns both `:changeset` and `:form` — covers all current consumers
- Override escape hatch via `ai_translate_assign_form/2` — future-proof

**`on_mount/4` return:**
- Returns `{:cont, socket}` — allows subsequent `on_mount` callbacks to run

### Findings

#### IMPROVEMENT - HIGH: Missing moduledoc note about double-fire scenario

The moduledoc should explicitly warn that a host defining its own `handle_info({:ai_translation, _, _}, socket)` will have **both** the host clause AND the hooked handler fire. The host clause must `{:halt, socket}` to prevent double-handling.

**Recommendation:** Add a "Host override" subsection to moduledoc.

#### NITPICK - LOW: `@doc false` on hook-internal functions

`__handle_event__/3` and `__handle_info__/2` are marked `@doc false` but are technically public. This is fine — the double-underscore prefix signals "internal use only". No action needed.

---

## 2. `media_detail.ex` — Leaf editor event forwarding

### Summary

Adds two `handle_info` clauses to forward Leaf editor events from the embedded `CommentsComponent`.

### Correctness

- Runtime module resolution via `Code.ensure_loaded/1` — appropriate for optional dependency
- Pattern matching on `{:leaf_changed, _}` — correct
- Catch-all prevents unmatched messages from crashing — correct and documented

### Findings

#### IMPROVEMENT - MEDIUM: Align with `MediaBrowser.Embed` pattern

Current implementation swallows `:pass` protocol and unexpected returns silently.

**Recommendation:** Align with `MediaBrowser.Embed` pattern:
- Use `apply/3` instead of direct call
- Handle `:pass` return value
- Log unexpected return values
- Use `Code.ensure_loaded?/1` (boolean) instead of `Code.ensure_loaded/1` (tuple)

---

## 3. Host-wiring Documentation (3 files, docs-only)

### Summary

All three files (`markdown_editor.ex`, `media_gallery.ex`, `media_selector_modal.ex`) add "required host wiring" sections documenting the callback-message contract.

### Quality

- Consistent "silent failure otherwise" framing across all three
- Explains why there's intentionally no Embed macro (handling varies per host)
- `media_selector_modal.ex` documents the `:notify` alternative for LiveComponent consumers
- Pure documentation changes — zero behavioral impact

### Findings

#### POSITIVE - HIGH: Consistent "silent failure" framing

Makes the contract discoverable and reduces integration bugs.

#### POSITIVE - MEDIUM: Documents the `:notify` alternative

Valuable for LiveComponent consumers — previously only discoverable via source reading.

#### SUGGESTION - LOW: Add "See also" cross-references

The three moduledocs could cross-reference each other.

---

## 4. V131 Migration

### Summary

Adds `metadata JSONB NOT NULL DEFAULT '{}'::jsonb` column to `phoenix_kit_staff_people`.

### Implementation Quality

- Idempotent `ADD COLUMN IF NOT EXISTS` — safe to re-run
- Explicit `::jsonb` cast — good practice
- Version marker via `COMMENT ON TABLE` — consistent pattern
- `prefix_str/1` helper — handles prefix correctly

### Documentation Quality

- Moduledoc explains immediate use case (soft-delete) and design rationale (generic column)
- Docblock entry in `postgres.ex` mirrors the migration moduledoc

### Findings

#### POSITIVE - HIGH: Mirrors `entity_data` pattern

Reusing a known shape reduces cognitive overhead.

#### POSITIVE - MEDIUM: Generic column, not feature-specific

Forward-looking design allowing future metadata without new migrations.

#### OBSERVATION - LOW: No index on `metadata`

Correct — not needed for primary-key lookups. Can be added later if query patterns change.

---

## Cross-cutting Analysis

### Pattern Stratification

Clear stratification for callback-message components:

| Approach | When to use | Example |
|----------|-------------|---------|
| **Embed macro** | Wiring identical across all hosts | `AITranslate.Embed` |
| **Moduledoc contract** | Handling varies per host | `MarkdownEditor`, `MediaGallery` |
| **Inline handler** | Only one host needs it | `media_detail.ex` |

This is the correct approach to the "silent failure" problem.

### Silent Failure Theme

The PR addresses a class of bugs where LiveComponent process messages are silently dropped. This PR:
- **Automates:** `AITranslate.Embed` makes wiring impossible to forget
- **Documents:** Three moduledocs explicitly warn "silent failure otherwise"
- **Fixes:** `media_detail.ex` adds the missing Leaf forwarding handler

---

## Severity Summary

| Severity | Count | Items |
|----------|-------|-------|
| **IMPROVEMENT - HIGH** | 1 | Document double-fire scenario in `AITranslate.Embed` moduledoc |
| **IMPROVEMENT - MEDIUM** | 1 | Align `media_detail.ex` leaf handler with `MediaBrowser.Embed` pattern |
| **POSITIVE** | 8 | Pattern stratification, consistent docs, generic metadata, idempotent migration, pure docs, `:notify` docs, mirrors entity_data, forward-looking |
| **NITPICK** | 1 | `@doc false` on internal functions |
| **SUGGESTION** | 2 | Cross-reference moduledocs, consider CHANGELOG entry |

---

## Verdict

**APPROVE.** Clean PR with four well-scoped commits:

1. **Macro** — `AITranslate.Embed` eliminates integration bugs via lifecycle hooks
2. **Bug fix** — Leaf forwarding in media detail with correct runtime module resolution
3. **Docs** — Three component moduledocs now explicitly document the callback-message contract
4. **Migration** — Minimal, idempotent, forward-looking column

### Non-blocking follow-ups

1. Add double-fire warning to `AITranslate.Embed` moduledoc (IMPROVEMENT - HIGH)
2. Align `media_detail.ex` leaf handler with `MediaBrowser.Embed` pattern (IMPROVEMENT - MEDIUM)
3. Consider CHANGELOG entry for the Leaf-forwarding bug fix
4. Consider cross-referencing the three documented components

---

## Fix Status — updated 2026-06-07 (commit `34cb7aac`)

| Finding | Status | Notes |
|---------|--------|-------|
| **IMPROVEMENT - MEDIUM** — Align `media_detail.ex` leaf handler with `MediaBrowser.Embed` | ✅ **Fixed** | `media_detail.ex` now mirrors the canonical handler: `function_exported?/2` guard, `apply/3` (avoids compile-time binding to the optional `phoenix_kit_comments` dep), explicit `:pass` handling, and `Logger.warning` on unexpected returns instead of silently swallowing them. |
| **IMPROVEMENT - HIGH** — Document double-fire scenario in `AITranslate.Embed` moduledoc | ⚠️ **Corrected, not as written** | The "double-fire" premise is inverted. Lifecycle hooks attached via `attach_hook` run **before** the LiveView's own callbacks, and the AI hook returns `{:halt, …}` for `{:ai_translation, …}` (and the six `ai_*` events). So a host clause for those messages is **shadowed — it never fires at all**; there is no double-handling and no need for the host to `{:halt}`. The moduledoc was updated with an *accurate* note (host clauses are shadowed by the halting hook; don't re-implement them) rather than the suggested warning. |
| **SUGGESTION** — CHANGELOG entry for the Leaf-forwarding fix | ⏭️ Deferred | Release-cut / CHANGELOG handled separately per PR body. |
| **SUGGESTION** — Cross-reference the three documented moduledocs | ⏭️ Skipped | Cosmetic; low value vs. churn. |
| **NITPICK** — `@doc false` on internal funcs | ⏭️ No action | Review concurs none needed. |

---

## File-by-File Checklist

- [x] `lib/phoenix_kit_web/components/ai_translate/embed.ex` — Read, analyzed, approved with minor suggestions
- [x] `lib/phoenix_kit_web/live/users/media_detail.ex` — Read, analyzed, approved with improvement recommendation
- [x] `lib/phoenix_kit_web/components/core/markdown_editor.ex` — Read, docs reviewed, approved
- [x] `lib/phoenix_kit_web/components/media_gallery.ex` — Read, docs reviewed, approved
- [x] `lib/phoenix_kit_web/live/components/media_selector_modal.ex` — Read, docs reviewed, approved
- [x] `lib/phoenix_kit/migrations/postgres/v131.ex` — Read, analyzed, approved
- [x] `lib/phoenix_kit/migrations/postgres.ex` — Read (relevant sections), approved

Generated by Mistral Vibe.
Co-Authored-By: Mistral Vibe <vibe@mistral.ai>
