# PR #585 Review — Host-wiring docs, AITranslate.Embed macro, media-detail Leaf fix, V131 migration

**Scope reviewed:** 4 commits by Max Don, merged as `ca6e8bd2`.

| Commit | Description |
|--------|-------------|
| `4d02510f` | Fix media detail comments: forward Leaf editor events to CommentsComponent |
| `42d45d58` | Add `AITranslate.Embed` macro for host wiring |
| `a9b1e1d0` | Document required host wiring on callback-message components |
| `f4157ee1` | Add V131 migration: `metadata JSONB` on staff people |

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

The module provides a `use`-macro that injects `on_mount` lifecycle hooks to wire the six `handle_event` clauses and one `handle_info` clause every consumer of `FormGlue` was hand-duplicating. The macro attaches hooks via `Phoenix.LiveView.attach_hook/4`, composing cleanly with a host's own handlers.

### Pattern consistency

Compared to the two existing Embed macros in the codebase:

| Aspect | `MediaBrowser.Embed` | `AITranslate.Embed` |
|--------|---------------------|---------------------|
| Hook mechanism | `@before_compile` + `on_mount` | `on_mount` only (`attach_hook`) |
| Handler injection | `def handle_event`/`def handle_info` clauses injected into module | `attach_hook` lifecycle hooks (no module-level defs) |
| Composition with host | Host clauses defined first win (module def ordering) | `attach_hook` composes — non-AI events return `{:cont, socket}` |

`AITranslate.Embed` uses the *lifecycle hook* approach consistently — no `@before_compile`, no injected `def` clauses. This is the cleaner pattern for new code because it avoids compiler-ordering subtleties and works regardless of how many Embed macros a host stacks. `MediaBrowser.Embed` uses `@before_compile` for legacy reasons (it also injects `handle_event("validate", …)` and conditional `handle_params` stubs that can't be hooks). The new Embed doesn't need any of that, so hooks-only is the right choice.

### Correctness

**Event routing (6 `handle_event` clauses):**

Each clause matches the exact event name and delegates to the corresponding `FormGlue` public function. Return is always `{:halt, socket}` — correct, since these are owned events that shouldn't fall through to the host. The catch-all `__handle_event__(_event, _params, socket)` returns `{:cont, socket}`, ensuring non-AI events pass through untouched. ✓

**`handle_info` clause:**

Matches `{:ai_translation, event, payload}` and delegates to `FormGlue.handle_ai_translation_event/4` with `&resync_form/2` as the re-assign callback. The catch-all returns `{:cont, socket}`. ✓

**`resync_form/2` override mechanism:**

The function checks `function_exported?(view, :ai_translate_assign_form, 2)` at runtime and falls back to assigning both `:changeset` and `:form`. This is the same `is_atom(view) and function_exported?/3` pattern used by `MediaBrowser.Embed` for its leaf-forwarder. Sound approach. Two observations:

1. **`is_atom(view)` guard is necessary.** `socket.view` can in theory be `nil` during disconnected render before the view module is resolved. The guard prevents a `function_exported?(nil, …)` crash. ✓
2. **Default superset is correct.** Every current consumer sets both `:changeset` and `:form` after merging. The override escape hatch handles future consumers with different form-sync patterns. ✓

**`on_mount/4` return:**

Returns `{:cont, socket}` — correct. `{:cont}` allows subsequent `on_mount` callbacks in the chain to run. ✓

### Findings

#### SUGGESTION — `Code.ensure_loaded` vs `Code.ensure_loaded?`

`resync_form/2` uses `function_exported?/3` directly (no `Code.ensure_loaded` guard). This is fine because `socket.view` is the *host LiveView module* — it is always loaded by the time `handle_info` fires (the process is running inside it). No action needed, just noting the deliberate difference from `media_detail.ex`'s `Code.ensure_loaded` of an optional cross-package module.

#### NITPICK — `@doc false` on public functions called via `attach_hook`

`__handle_event__/3` and `__handle_info__/2` are `@doc false` but technically public. They're only callable via the closure captured in `attach_hook`, not via the module's public API. This matches the convention in `MediaBrowser.Embed` (its `on_mount/4` is also `@doc false`). Fine as-is — the naming with double-underscore prefix makes the intent clear.

#### OBSERVATION — no `@before_compile` fallback for hosts that already define `handle_info`

Unlike `MediaBrowser.Embed` (which injects fallback `def handle_info` via `@before_compile`), this macro uses only `attach_hook`. This means a host that does `use AITranslate.Embed` *and* defines its own `handle_info({:ai_translation, _, _}, socket)` will have **both** run: the host's clause first (module def), then the hook. The host's clause would need to `{:halt, socket}` to prevent double-handling. This is not a bug — `attach_hook` semantics are well-documented — but worth calling out in the moduledoc for hosts that might want to handle `:ai_translation` events themselves. The existing moduledoc's "How it composes" section partially covers this but could explicitly mention the double-fire scenario.

---

## 2. `media_detail.ex` — Leaf editor event forwarding

### Summary

Two new `handle_info` clauses:

1. `handle_info({:leaf_changed, _} = msg, socket)` — resolves `PhoenixKitComments.Web.CommentsComponent` at runtime via `Code.ensure_loaded/1` and delegates to `forward_leaf_event/2`.
2. `handle_info(_msg, socket)` — catch-all, returns `{:noreply, socket}`.

### Correctness

**Runtime module resolution is appropriate here.** `phoenix_kit_comments` is an optional dependency — it may or may not be loaded. `Code.ensure_loaded/1` returns `{:module, mod}` or `{:error, _}`, and the code safely no-ops on the error path. ✓

**Pattern match on `{:leaf_changed, _}` is correct.** The Leaf editor sends `{:leaf_changed, %{editor_id: ..., content: ...}}` process messages. The wildcard `_` captures any payload shape. ✓

**Catch-all is required and correctly noted.** The inline comment explains that defining any `handle_info` removes LiveView's default handler, so the catch-all prevents unmatched messages from crashing. ✓

### Findings

#### MINOR — return value handling differs from `MediaBrowser.Embed`

```elixir
# media_detail.ex (this PR)
case mod.forward_leaf_event(msg, socket) do
  {:noreply, socket} -> {:noreply, socket}
  _ -> {:noreply, socket}
end

# MediaBrowser.Embed (existing)
case apply(mod, :forward_leaf_event, [msg, socket]) do
  {:noreply, _} = result -> result
  :pass -> {:noreply, socket}
  other ->
    Logger.warning("... returned unexpected value: #{inspect(other)}")
    {:noreply, socket}
end
```

The `media_detail.ex` version is simpler but discards the `:pass` protocol and swallows unexpected returns silently. The `MediaBrowser.Embed` version uses `apply/3` (safer for cross-package calls), handles `:pass`, and logs unexpected returns. For a one-off handler in a specific LiveView, the simpler version is acceptable — but it's worth noting the pattern divergence. If `forward_leaf_event/2` ever starts returning `:pass` for leaf events that should continue bubbling, this handler will silently swallow them.

**Recommendation:** Align with the `MediaBrowser.Embed` pattern (handle `:pass`, log unexpected returns). Low urgency since this is a single LiveView, not a shared macro.

#### NOTE — `forward_leaf_event` called with `mod.forward_leaf_event(msg, socket)`

Direct call (not `apply/3`). This works because `media_detail.ex` is inside `phoenix_kit` core, and `phoenix_kit_comments` is a sibling that will be loaded by the time the code path executes (guarded by `Code.ensure_loaded`). `MediaBrowser.Embed` uses `apply/3` because it's injected into *host* modules where the compile-time binding is undesirable. Here, the direct call is fine. ✓

---

## 3. Host-wiring docs (3 files, docs-only)

### `markdown_editor.ex`

Added a new **"Events Sent to Parent — required host wiring (silent failure otherwise)"** section to `@moduledoc`. Documents three process messages:

- `{:editor_content_changed, %{content: content, editor_id: id}}` — **required**
- `{:editor_insert_component, %{type: :image | :video, editor_id: id}}` — optional
- `{:editor_save_requested, %{editor_id: id}}` — optional

Explicitly calls out that forgetting `{:editor_content_changed, …}` means "the editor looks live but the parent never sees the typed content — no crash, no warning." This is the key documentation gap that `AITranslate.Embed` eliminates for the AI translate path — the docs correctly acknowledge that `MarkdownEditor` intentionally has no Embed macro because "each host folds the content into its own form differently." ✓

### `media_gallery.ex`

Added a **"Change notifications — required host wiring (silent failure otherwise)"** section. Documents the `{PhoenixKitWeb.Components.MediaGallery, id, {:changed, ordered_uuids}}` message with a usage example. Same intentional-no-Embed explanation as `MarkdownEditor`. ✓

Added a **"Reorder event contract"** section explaining the `reorder_images` event routing via `pushEventTo` with `target`. Useful for hosts debugging why their reorder events don't arrive. ✓

### `media_selector_modal.ex`

Added a **"Required host wiring (do not skip — silent failure otherwise)"** section with:
- `{:media_selected, file_uuids}` — **required**
- `{:media_selector_closed}` — recommended

Also documents the alternative `:notify` path (`send_update` to a component instead of `send/2` to the LiveView). This is important context that was previously only discoverable by reading the component's source. ✓

### Findings

#### POSITIVE — consistent "silent failure" framing

All three docs use the same pattern: bold header with "silent failure otherwise", explanation that `LiveComponent` uses `send/2` process messages, and why there's intentionally no Embed macro. This consistency makes the contract discoverable and reduces the chance of a host accidentally omitting a handler.

#### POSITIVE — no code changes, pure docs

The three files have zero behavioral changes. Only `@moduledoc` additions. Safe to backport, no test impact. ✓

---

## 4. V131 Migration (`v131.ex` + `postgres.ex`)

### Summary

Adds `metadata JSONB NOT NULL DEFAULT '{}'::jsonb` to `phoenix_kit_staff_people`, bumps `@current_version` to 131, adds a docblock for V131 in the main migration module.

### Correctness

**Idempotent `ADD COLUMN IF NOT EXISTS`:** ✓ Safe to re-run.

**`NOT NULL DEFAULT '{}'::jsonb`:** Matches the `entity_data` pattern. The `::jsonb` cast is explicit, which is good practice. ✓

**Version marker via `COMMENT ON TABLE`:** Same pattern as all recent migrations. `down/1` reverts to `'130'`. ✓

**`prefix_str/1` helper:** Private function handles `"public"` → `"public."` and other prefixes → `"#{prefix}."`. Same pattern as other migrations. ✓

**`use Ecto.Migration`:** Standard. The `up/1` and `down/1` accept `opts` with prefix. ✓

### Findings

#### POSITIVE — mirrors `entity_data` pattern

The moduledoc explicitly calls out that this mirrors `phoenix_kit_entities.entity_data`. Reusing a known shape reduces cognitive overhead for future consumers.

#### POSITIVE — generic column, not feature-specific

Using `metadata` instead of a `trashed_from_status`-specific column is forward-looking. The docstring explains the immediate consumer (soft-delete) and the rationale for generality. ✓

#### OBSERVATION — no index on `metadata`

No GIN index on the JSONB column. This is correct for the current use case — `metadata` will be read by primary key lookup (`SELECT ... WHERE uuid = ?`), not by JSONB path queries. Adding a GIN index now would be speculative. If future consumers query against `metadata` keys, an index can be added in a later migration. ✓

#### OBSERVATION — `down/1` is lossy but documented

Dropping the column loses any metadata written after V131. This is consistent with the migration convention — `down/1` is for development rollback, not production reversal. No action needed.

---

## Cross-cutting concerns

### Consistent "silent failure" pattern

This PR is part of a broader effort to document (and macro-ize) the "LiveComponent sends process messages that the host must handle" contract. The three doc-only files address the documentation side; `AITranslate.Embed` addresses the automation side. The media_detail fix addresses a concrete instance of the same problem (Leaf editor events going nowhere).

The pattern is:
1. **Embed macro** — when the wiring is identical across all hosts (AI translate events)
2. **Moduledoc contract** — when the handling varies per host (content changes, gallery selections)
3. **Inline handler** — when only one host needs it (media detail's Leaf forwarding)

This is the right stratification.

### Version numbering gap (V70–V130 → V131)

V131 jumps from V70 (the last "sequential" version in the older range) to V131. This is because V71+ were already used for the UUID migration sequence. The migration dispatcher (`postgres.ex`) resolves versions numerically, so V131 simply runs after V130. No issue, just noting the gap for future readers.

---

## Verdict

**Approve.** Clean PR with four well-scoped commits, each doing one thing:

1. **Bug fix** — Leaf forwarding in media detail, with correct runtime module resolution and the required catch-all.
2. **Macro** — `AITranslate.Embed` eliminates a class of integration bugs via `attach_hook` lifecycle hooks, consistent with the `on_mount` approach used by `MediaBrowser.Embed` for its url_sync path.
3. **Docs** — Three component moduledocs now explicitly document the "handle this or it silently fails" contract.
4. **Migration** — Minimal, idempotent, generic-purpose column following established patterns.

### Minor follow-ups (non-blocking)

1. **Align `media_detail.ex` leaf handler** with `MediaBrowser.Embed`'s pattern (handle `:pass`, log unexpected returns). Low urgency.
2. **Consider noting double-fire scenario** in `AITranslate.Embed` moduledoc for hosts that define their own `handle_info({:ai_translation, _, _})`.
3. **Consider adding a `CHANGELOG` entry** for the Leaf-forwarding bug fix (user-visible fix).

---

## Fix Status — updated 2026-06-07 (commit `34cb7aac`)

| Follow-up | Status | Notes |
|-----------|--------|-------|
| 1. Align `media_detail.ex` leaf handler with `MediaBrowser.Embed` | ✅ **Fixed**, then **superseded by extraction** (see below) | First aligned `media_detail.ex` to the canonical handler (`function_exported?/2` guard, `apply/3`, `:pass` handling, `Logger.warning` on unexpected returns) in `34cb7aac`. A follow-up code review flagged the resulting near-verbatim duplication; resolved by extraction. |
| 2. Note double-fire scenario in `AITranslate.Embed` moduledoc | ⚠️ **Corrected, not as written** | The "double-fire" premise is inverted. Lifecycle hooks run **before** the LiveView's own callbacks, and the AI hook returns `{:halt, …}` for `{:ai_translation, …}` (and the six `ai_*` events). So a host clause for those messages is **shadowed — it never fires**; there is no double-handling and the host need not `{:halt}`. The moduledoc was updated with an *accurate* note (host clauses are shadowed by the halting hook; don't re-implement them). Mistral's review raised the same point with the same inverted framing — see `MISTRAL_REVIEW.md` Fix Status. |
| 3. CHANGELOG entry for the Leaf-forwarding fix | ⏭️ Deferred | Release-cut / CHANGELOG handled separately per PR body. |

### Follow-up — shared helper extraction (commit `d9a483a2`)

This review's cross-cutting section noted the "inline when only one host needs it" stratification justified the inline `media_detail.ex` handler. Once the MEDIUM alignment made that handler near-identical to `MediaBrowser.Embed`'s, a follow-up code review flagged the duplication as a concrete maintenance cost — two copies of the optional-dep contract to keep in lock-step.

Resolved by extracting **`PhoenixKitWeb.CommentsForwarding.forward_leaf_changed/2`** (`lib/phoenix_kit_web/comments_forwarding.ex`). Both `media_detail.ex` and the `MediaBrowser.Embed` macro now delegate to it; the `phoenix_kit_comments` `forward_leaf_event/2` contract lives in one module. Bonus: the `MediaBrowser.Embed` macro no longer injects `require Logger` into hosts (the only `Logger` use moved into the shared module). `mix precommit` green (compile/credo/dialyzer).
