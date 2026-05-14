# PR #541 Review — V118: callout/text annotation kinds + Etcher 0.2

**Status:** Merged (commit `7673e543`). Review for post-merge follow-up.
**Author:** @alexdont
**Scope (declared, from title only — PR body is empty):** "Updated the media browser, fresco and etcher."

What the PR actually does:

1. **V118 migration** — widens `phoenix_kit_annotations_kind_check` for `"callout"` and `"text"`, adds optional `title VARCHAR(200)` column.
2. **Schema + context** — `Annotations.Annotation` gains `:title` field (validated max 200) and the two new kinds; `Annotations.restore_linked_comments/3` undeletes comments cascade-removed by `delete/1`.
3. **`AnnotationComposer`** — adds the title input, allows title-only posts (no comment thread create), bumps `phx-debounce` 150 → 500 to tame keystroke chatter, splits the post path into `post_with_comment/3` + a title-only branch.
4. **`MediaBrowser`** —
   - `etcher:updated` now accepts any combination of `geometry / style / metadata / title` in one payload (previously geometry-only).
   - On `kind == "text"` or `restore: true`, the composer popover is suppressed (text shapes carry their content inline; restores already have everything).
   - `restore: true` + `restore_from_uuid` triggers `restore_linked_comments/3` and refreshes the comments sidebar.
   - Etcher overlay now attaches even when Tessera variants haven't been generated — previously the `[]` branch fell back to a plain `<img>` with no annotation overlay.
   - Viewer keydown moves from `phx-window-keydown="viewer_keydown"` to `phx-hook="ViewerKeydown"`, with focus-aware filtering so arrow keys don't flip slides while typing in the composer.
5. **JS de-duplication** — `priv/static/assets/phoenix_kit.js` drops 584 lines of inlined fresco/tessera/etcher hooks (`8abcee45`) and now adopts `window.{Fresco,Tessera,Etcher}Hooks` from each lib's own bundle. `mix.exs` bumps `{:etcher, "~> 0.1"}` → `"~> 0.2"`.

Headline takeaway: the substantive changes are sound and the user-facing wins (annotations on un-tessellated files, focus-aware keydown, undo-of-delete that brings the comments back) are real improvements. Findings below are mostly migration ergonomics and two small write-path inconsistencies.

---

## BUG — MEDIUM

### #1 `etcher:updated` saves `title = ""` to DB instead of `NULL`

Two write paths now disagree on the canonical "no title" representation:

- **Composer path** (`finalize_annotation_compose/3` at `media_browser.ex:1689-1698`) trims blanks and normalizes `""` → `nil`, so the DB row keeps `title = NULL`.
- **Etcher inline-edit path** (`etcher:updated` → `apply_annotation_update/4` at `media_browser.ex:1117-1130`) builds `update_attrs` via `maybe_put_payload/3`, which guards only against `nil`:

  ```elixir
  defp maybe_put_payload(attrs, key, params) do
    case Map.fetch(params, key) do
      {:ok, value} when not is_nil(value) -> Map.put(attrs, key, value)
      _ -> attrs
    end
  end
  ```

  Empty strings pass through, so `EtcherAdapter.update(uuid, %{"title" => ""})` writes `title = ""` to the column.

**Why it matters:** anyone querying "annotations with a title" (`where: not is_nil(a.title)`) will get false positives for shapes the user cleared via the inline editor. The composer-created shapes are correctly `NULL`. Predicates and analytics get noisy.

**Fix:** apply the same trim-blank-to-nil normalization in `apply_annotation_diff` / `maybe_put_payload` for the `"title"` key — or do it once in `EtcherAdapter.update` before persistence.

---

## IMPROVEMENT — MEDIUM

### #2 V118 `down/1` crashes when callout/text rows exist; drops `title` data unconditionally

`down/1` does, in order:

1. `DROP COLUMN IF EXISTS title` — silently destroys every populated title.
2. `DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check`.
3. `ADD CONSTRAINT ... CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand'))`.

Step 3 raises `check_violation` if any row has `kind IN ('callout', 'text')`. The rollback is then half-applied: column gone, constraint missing.

Project convention does not preserve data in `down/1` (V115/V116/V117 are the same shape), so this is consistent with the codebase — but **rolling back V118 on a database that has actually been used is now a manual operation**. At minimum the moduledoc should say "down/1 assumes no callout/text rows exist; delete them first," and the column DROP could be reordered after the constraint to fail-fast before destroying title data.

### #3 V118 docstring overclaims idempotence

Both the migration moduledoc and `postgres.ex` summary say "Both operations are idempotent (`IF NOT EXISTS` / `DO $$` guards) so re-running on a partially-applied schema is a no-op."

Re-running the CHECK block actually drops-and-re-adds the constraint (step 1 always runs), so it's not a no-op — it's a re-creation. Harmless, but the doc is slightly inaccurate. Either drop the `DROP CONSTRAINT` and rely on the `DO $$ IF NOT EXISTS` guard, or rewrite "no-op" → "harmless re-recreation." The former is the cleaner intent.

### #4 `finalize_annotation_compose/3` swallows title-save errors silently

```elixir
_ = PhoenixKit.Annotations.update(annotation_uuid, %{title: title_val})
```

If `validate_length(:title, max: 200)` rejects (e.g. someone bypassed the `maxlength="200"` HTML attr via DevTools, or future code lets a longer string through), the user sees a successful post and the title silently fails to save. The shape renders without its title and there's no log line to chase. A `Logger.warning/1` on the `{:error, cs}` branch is cheap and would save a future debugging session.

---

## NITPICK

### #5 Title input is a raw `<input>`, not `<.input>` from `Components.Core.Input`

Per `AGENTS.md` (the file you're reading this in): "`PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}` — canonical form primitives. Use over raw `<input>`/`<select>`/`<textarea>` in new code." The new title field at `annotation_composer.ex:363-371` bypasses the core component (so does the pre-existing `<textarea>` next to it — not introduced by this PR, but worth folding into the same cleanup). The component is wired for `name=` / `value=` directly, so the migration is mechanical:

```heex
<.input
  type="text"
  name="title"
  value={@new_title}
  maxlength="200"
  phx-debounce="500"
  class="input-sm text-sm"
  placeholder={gettext("Optional title (shows on the shape)")}
/>
```

### #6 Title placeholder bypasses gettext

`placeholder="Optional title (shows on the shape)"` is the only user-visible string in this PR that isn't routed through `gettext/1`. Every other label/flash is wrapped (`gettext("Add a title, a note, a GIF, or an attachment")`, etc.). Bare string here breaks i18n for that one tooltip.

### #7 `maybe_set_title_in_metadata/2` keys `metadata.title` on the in-memory struct but doesn't touch the schema's `:title` field

```elixir
defp apply_annotation_diff(annotation, params) do
  annotation
  |> maybe_assign_field(:geometry, ...)
  |> maybe_assign_field(:style, ...)
  |> maybe_merge_metadata(...)
  |> maybe_set_title_in_metadata(Map.get(params, "title"))   # writes to a.metadata.title only
end
```

After an `etcher:updated` with a new title, the in-memory `annotation.title` field stays stale until `load_annotations_for/1` reloads from DB. The render path uses `metadata.title` (via `to_etcher_payload/1` merging the column into metadata), so visually nothing is wrong — but if any caller reads `a.title` between the inline-edit and the next reload, it lags. Cheap fix: `Map.put(map, :title, value)` in `maybe_set_title_in_metadata/2` alongside the metadata merge.

### #8 `restore_linked_comments/3` per-comment updates

The function filters then `Enum.reduce`s `PhoenixKitComments.update_comment/2` one row at a time. For undo-of-delete on a single annotation with N comments, that's N round-trips. Realistic N is small (single-digit), so an `Ecto.Multi` / bulk update is overkill — flagged for completeness only, not for action.

---

## GOOD CALLS — worth keeping visible

- **Etcher attaches without Tessera.** Pre-PR, files without medium/large/dzi variants got a plain `<img>` and the annotation overlay simply didn't exist. Now Fresco + Etcher render unconditionally; Tessera attaches only when there are sources to swap between. Annotations on fresh uploads now Just Work.
- **`phx-window-keydown` → `phx-hook="ViewerKeydown"` with focus filter.** The hook explicitly bails when `document.activeElement` is an INPUT/TEXTAREA/contenteditable, fixing the "typing in the composer flips to the next image" bug that `phx-window-keydown` couldn't express. Right shape for the constraint.
- **Composer suppression on `kind == "text"` and `restore: true`.** Both are correct UX calls — text shapes carry content inline via etcher's foreignObject editor; restores already have title/metadata. Ambushing the user with the composer on either would be wrong.
- **`restore_linked_comments/3` re-links via `metadata.annotation_uuid` rewrite.** The original annotation uuid is gone, the soft-deleted comments still reference it, and the function correctly flips them to `"published"` while pointing them at the new uuid. Solid undo-of-delete semantics.
- **JS bundle de-duplication.** 584 lines of inlined fresco/tessera/etcher hooks removed from `phoenix_kit.js` in favor of upstream package bundles (`8abcee45`). Eliminates the drift between phoenix_kit's snapshot and the hex packages — exactly the right direction.
- **`phx-debounce` 150 → 500 on the composer textarea.** Quieter LV logs, no perceived input lag at typical typing speeds.

---

## Disposition summary

| # | Severity | Title | Suggested action |
|---|---|---|---|
| 1 | BUG-MEDIUM | `etcher:updated` saves `title = ""` instead of `NULL` | Normalize blank → nil in `maybe_put_payload`/`apply_annotation_diff` |
| 2 | IMPROVEMENT-MEDIUM | V118 `down/1` data loss + crash path | Reorder operations; document assumption in moduledoc |
| 3 | IMPROVEMENT-MEDIUM | V118 idempotence claim inaccurate | Drop the unconditional `DROP CONSTRAINT` or fix the doc |
| 4 | IMPROVEMENT-MEDIUM | Silent title-save failure in `finalize_annotation_compose` | Add `Logger.warning/1` on `{:error, _}` |
| 5 | NITPICK | Raw `<input>` instead of `<.input>` | Mechanical swap |
| 6 | NITPICK | Title placeholder not gettext-wrapped | Wrap in `gettext/1` |
| 7 | NITPICK | In-memory `:title` field stays stale after inline edit | Also `Map.put(map, :title, value)` in `maybe_set_title_in_metadata/2` |
| 8 | NITPICK | Per-row update loop in `restore_linked_comments/3` | Leave as-is; N is small |

Nothing here blocks the merge or warrants a follow-up patch on its own. #1 is the only one that has lasting behavioral consequences (false positives on `where: not is_nil(a.title)` queries); if a future PR touches the annotation write paths, it's worth bundling the normalization fix in.
