# PR #537 Review — Annotations V115 + Etcher Overlay + AnnotationComposer LV

**Status:** Merged. Review for post-merge follow-up.
**Scope:** V115 migration (`phoenix_kit_annotations`), `PhoenixKit.Annotations` context, `EtcherAdapter` storage backend, `AnnotationComposer` LiveComponent, MediaBrowser integration (viewer events, lifecycle, sidebar refresh), Etcher tooltip slot overrides + composer-position JS hook, fresco/tessera/etcher dep pinning, version bump 1.7.108 → 1.7.109.

Overall a well-architected feature — clean separation between the storage adapter (Etcher contract) and the context (PhoenixKit-native API), lifecycle semantics for "solidify on Post / rollback on Cancel" thread through the MediaBrowser cleanly, JS payload key whitelisting in the adapter handles forward-compat with Etcher payload churn. Issues below are mostly polish + one real consistency hole around deletion atomicity and resource_type docstring drift.

---

## BUG — MEDIUM

### #1 `Annotations.delete/1` deletes linked comments outside a transaction

`lib/phoenix_kit/annotations/annotations.ex:222-252`

```elixir
def delete(uuid) do
  case RepoHelper.get(Annotation, uuid) do
    nil -> {:error, :not_found}
    annotation ->
      delete_linked_comments(annotation)     # ← runs first
      case RepoHelper.delete(annotation) do  # ← can fail
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
  end
end
```

If `delete_linked_comments/1` succeeds and `RepoHelper.delete(annotation)` then fails (FK violation from a future cascading reference, DB transient, etc.), the comments are gone but the annotation row remains — its discussion permanently destroyed but the pin still on the image. The reverse order would be just as bad (comments orphaned on annotation row). Both writes need to be atomic.

**Fix:** wrap in `RepoHelper.repo().transaction/1`:

```elixir
RepoHelper.repo().transaction(fn ->
  delete_linked_comments(annotation)
  case RepoHelper.delete(annotation) do
    {:ok, _} -> :ok
    {:error, cs} -> RepoHelper.repo().rollback(cs)
  end
end)
```

This also addresses the comment-side `rescue _ -> :ok` silently swallowing partial-cascade failures (see #5).

### #2 `resource_type = "annotation"` is documented in three places but the implementation uses `"file"`

`lib/phoenix_kit/annotations/annotation.ex:11-17`
`lib/phoenix_kit/annotations/annotations.ex:7-11`
`lib/phoenix_kit/migrations/postgres/v115.ex:8-11`

All three say the discussion thread lives under `resource_type = "annotation"` + `resource_uuid = annotation.uuid`. The actual implementation (`annotation_composer.ex:113-117`, `annotations.ex:99` filter on `metadata.annotation_uuid`) anchors comments to the **file** (`resource_type = "file"`, `resource_uuid = file_uuid`) and uses `metadata.annotation_uuid` for the back-reference. Annotations.ex:62-66 documents the actual implementation, contradicting its own moduledoc on lines 11-17.

This is more than docstring drift — it's a load-bearing architectural decision that needs to be consistent. The "comments on the file with annotation metadata" pattern lets the comments appear in the file's main thread alongside non-annotated discussion, which is a real UX choice. But anyone reading the docs first will wire consumer code expecting the wrong shape.

**Fix:** sweep all three moduledocs to say `resource_type = "file"` + `metadata.annotation_uuid`. The V115 migration moduledoc in particular needs accuracy since it's the closest thing to durable docs.

---

## BUG — LOW

### #3 Race condition between `composer_posted` and viewer navigation

`lib/phoenix_kit_web/components/media_browser.ex:1497-1540`

`open_viewer/2` (called on close/step/escape) invokes `rollback_pending_annotation_if_any/1`, which deletes the pending annotation when `composing_annotation_uuid` is non-nil. The composer's `send_update(..., action: :annotation_composer_posted, ...)` flips `composing_annotation_uuid` to nil **inside** `finalize_annotation_compose/2`.

If the user clicks "Post" and immediately presses Escape (or arrow-navigates), both messages can arrive in any interleaving. LiveView serializes them — but the issue is the **state at the moment each handler reads `composing_annotation_uuid`**:

- If `rollback_pending_annotation_if_any` runs first, it deletes the annotation (the comment is already created and now orphaned — its `metadata.annotation_uuid` points at a deleted row).
- If `finalize_annotation_compose` runs first, the rollback then sees `nil` and is a no-op. Good.

`send_update` from a LiveComponent is processed before subsequent `handle_event`s, so in practice this should be OK — but the order isn't formally guaranteed if the rollback was triggered via a navigation `send/2` to self before the Post message landed. Worth either:

1. Setting `composing_annotation_uuid` to nil **before** the network round-trip in the composer (optimistic local state), OR
2. Tagging the rollback with the annotation_uuid and only acting if it still matches (the no-op case becomes explicit instead of "saw nil").

Probability is low (sub-100ms window between Post-click and an Escape keypress), but the failure mode (orphaned comment with broken back-ref) is hard to debug if it ever lands.

### #4 Partial upload state on attachment failure in `AnnotationComposer`

`lib/phoenix_kit_web/components/annotation_composer.ex:262-265`

```elixir
case Enum.split_with(results, &match?({:ok, _}, &1)) do
  {oks, []} -> {:ok, Enum.map(oks, fn {:ok, uuid} -> uuid end)}
  {_, [{:error, reason} | _]} -> {:error, "Upload failed: #{inspect(reason)}"}
end
```

If two files are queued and the second fails to store, the first one's storage row is already created (and not rolled back). The composer returns the error and the user sees "Upload failed" — but the orphaned first attachment is in storage forever, unreferenced. Two issues bundled:

1. **No rollback**: should `Storage.delete_file/1` (or trash, depending on the storage policy) the successful entries when any entry fails.
2. **`inspect(reason)` in user-facing message**: leaks internals (`%Ecto.Changeset{...}` or `{:error, :enoent}`) into the flash. Should map to user-friendly strings.

### #5 Bare `rescue _ -> :ok` in `delete_linked_comments`

`lib/phoenix_kit/annotations/annotations.ex:247-252`

```elixir
defp delete_linked_comments(annotation) do
  if Code.ensure_loaded?(PhoenixKitComments) do
    ...
    |> Enum.each(&PhoenixKitComments.delete_comment/1)
  end
rescue
  _ -> :ok
end
```

Mirror of the C12-sweep finding from PR #536: this rescue catches `KeyError`, `MatchError`, `ArgumentError`, and every other logic bug, silently returning `:ok`. The comment justifies it as "swallow comment-side errors so an annotation can still be deleted" — but a logic bug here will then make the deletion appear to succeed while the comments stay, leaving the user with "[removed]" placeholders that point at a gone annotation. Should narrow to expected exception classes:

```elixir
rescue
  e in [DBConnection.OwnershipError, Postgrex.Error, ArgumentError] ->
    Logger.warning("[Annotations] delete_linked_comments: #{Exception.message(e)}")
    :ok
end
```

---

## IMPROVEMENT — MEDIUM

### #6 No authorization check on annotation update/delete

`lib/phoenix_kit_web/components/media_browser.ex:1087-1110`

`etcher:updated` and `etcher:deleted` accept any uuid from the client and act on it. There's no "current user is the creator OR an admin" guard. For the current admin-only `/admin/media` route this is acceptable (admin scope = full access), but the MediaBrowser is exposed via the `Embed` macro for arbitrary consumers, and the comment at `media_browser.ex:1112-1116` explicitly anticipates future user-facing embeds ("v0.1: selection is informational only; consumer UI can wire a selected-annotation panel here later"). A non-admin embed today inherits zero authz.

**Fix shape:** pull `creator_uuid` from the loaded annotation and compare against the scope. Admin override via `Scope.admin?/1`. Either inline or factor into a `can_modify_annotation?/2` helper.

### #7 `String.to_existing_atom` in adapter trusts `@schema_keys` to actually exist

`lib/modules/storage/etcher_adapter.ex:71-76`

```elixir
defp filter_to_schema(attrs) do
  Enum.reduce(attrs, %{}, fn {k, v}, acc ->
    key = to_string(k)
    if key in @schema_keys, do: Map.put(acc, String.to_existing_atom(key), v), else: acc
  end)
end
```

Safe **today** because the schema (`Annotation`) defines every key in `@schema_keys`, so those atoms exist at load time. But the safety depends on a load-order invariant that isn't documented and isn't enforced — if anyone removes a field from the schema without updating `@schema_keys`, the function silently never matches the dropped key (since the atom wouldn't exist) until someone adds it back. The same load-order coupling caused the bug the original commit set out to fix ("`String.to_existing_atom` on unknown payload keys used to crash the LV").

Two cleaner shapes:

1. Hardcode atoms in `@schema_keys` (`[:kind, :geometry, ...]`) and compare against `String.to_atom/1` of the input — but with a strict whitelist this is safe.
2. Define the whitelist on the `Annotation` schema itself (e.g. as `Annotation.cast_fields/0`) so the schema is the single source of truth.

Option 2 is preferable — couples the adapter to the schema by API rather than by string convention.

### #8 `AnnotationComposer` flash messages aren't gettext-wrapped

`lib/phoenix_kit_web/components/annotation_composer.ex:134-150, 264, plus all template text`

Every user-facing string is hardcoded English: `"Could not post comment"`, `"Add some text, a GIF, or an attachment"`, `"Attachments are disabled"`, `"Up to N attachments"`, `"Upload failed: …"`, plus the heex labels `"Write a note about this annotation..."`, `"GIF"`, `"File / Image"`, `"Search GIFs..."`, `"Type to search GIFs."`, `"No results."`, etc. Inconsistent with the rest of the codebase, which uses `gettext(...)` for all user-visible text. Even the parent MediaBrowser correctly gettext-wraps its annotation strings.

This is a moderate scope sweep (10-15 strings) but mechanical.

### #9 `geometry` shape is not validated per `kind`

`lib/phoenix_kit/annotations/annotation.ex:55-63`

```elixir
def changeset(annotation, attrs) do
  annotation
  |> cast(attrs, @cast_fields)
  |> validate_required(@required_fields)
  |> validate_inclusion(:kind, @kinds)
  |> foreign_key_constraint(:file_uuid)
  ...
end
```

`geometry` is required but free-form `:map`. A rectangle with `%{"points" => [[1,2]]}` (wrong shape for `kind: "rectangle"`) is accepted. A polygon with `%{"x" => 0}` lands in the DB. The JS rendering then either silently fails to draw the shape or throws.

V115 enforces the **kind** at the DB level via CHECK but does nothing for geometry. The schema's docstring spells out the per-kind shape contract:

```
* rectangle: `{x, y, w, h}`
* circle:    `{cx, cy, r}`
* polygon:   `{points: [[x, y], ...]}`
* freehand:  `{points: [[x, y], ...]}`
```

But nothing enforces it. **Fix:** a `validate_geometry/1` step in the changeset that dispatches on `:kind` and validates the expected keys with sensible numeric bounds.

```elixir
def changeset(annotation, attrs) do
  annotation
  |> cast(attrs, @cast_fields)
  |> validate_required(@required_fields)
  |> validate_inclusion(:kind, @kinds)
  |> validate_geometry()
  |> ...
end

defp validate_geometry(changeset) do
  with %{kind: kind, geometry: geometry} when is_map(geometry) <- changeset.changes do
    validate_geometry_shape(changeset, kind, geometry)
  else
    _ -> changeset
  end
end
```

### #10 Hardcoded CommentsComponent id in `refresh_file_comments`

`lib/phoenix_kit_web/components/media_browser.ex:1593-1604`

```elixir
defp refresh_file_comments(socket) do
  with %{file_uuid: file_uuid} when is_binary(file_uuid) <- socket.assigns[:viewer_file],
       true <- Code.ensure_loaded?(PhoenixKitComments.Web.CommentsComponent) do
    Phoenix.LiveView.send_update(PhoenixKitComments.Web.CommentsComponent,
      id: "media-comments-" <> file_uuid,
      loaded?: false
    )
  end
  :ok
end
```

The id `"media-comments-" <> file_uuid` is the convention the MediaBrowser template uses — but consumers who embed CommentsComponent under a different id silently get nothing. `send_update/2` with a non-existent id is a quiet no-op.

For the current single-consumer setup this is fine. If MediaBrowser is ever embedded somewhere that also wants to use the annotation-comment flow with a different CommentsComponent layout, this convention has to be either configurable (`:comments_component_id` attr defaulting to current shape) or replaced with a PubSub broadcast that interested components subscribe to.

---

## IMPROVEMENT — LOW

### #11 `normalize/1` in `Annotations` reinvents what `cast/3` already does

`lib/phoenix_kit/annotations/annotations.ex:257-264`

```elixir
defp normalize(attrs) when is_map(attrs) do
  Enum.into(attrs, %{}, fn
    {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    {k, v} -> {k, v}
  end)
rescue
  ArgumentError -> attrs
end
```

`Ecto.Changeset.cast/3` accepts both atom- and string-keyed maps natively. This helper adds:

1. Risk of silently passing through the original map (with string keys) when any single key can't be converted, after which the changeset's `cast/3` happily processes the string keys it recognizes and ignores the rest. A typo like `"geomerty"` lands in the second category and the user gets a misleading "geometry: can't be blank" error rather than "unknown field".
2. No actual benefit — `cast/3` does the conversion for the fields it knows about.

**Fix:** delete `normalize/1`, pass `attrs` straight through. The changeset's whitelist handles unknown keys.

### #12 Defensive `Code.ensure_loaded?(PhoenixKit.Annotations)` guard for in-repo module

`lib/phoenix_kit_web/components/media_browser.ex:1606-1610`

```elixir
defp load_annotations_for(file_uuid) do
  if Code.ensure_loaded?(PhoenixKit.Annotations) and
       function_exported?(PhoenixKit.Annotations, :list_for_file_with_previews, 1) do
    ...
```

`PhoenixKit.Annotations` is in the same compilation unit as `MediaBrowser` — it can't fail to load, can't be missing `list_for_file_with_previews/1`. The guard pattern is borrowed from the optional `PhoenixKitComments` usage two lines below, but here it's needless cruft. Drop the guard, call directly.

### #13 `format_date/1` not locale-aware

`lib/phoenix_kit_web/components/media_browser.ex:1657-1659`

```elixir
defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")
```

Renders "May 12, 2026" in English regardless of the user's locale. The codebase has `time_ago` and similar helpers in `PhoenixKitWeb.Components.Core.TimeDisplay` — worth reusing those for consistency or running the format string through gettext. Same issue as #8.

### #14 `AnnotationComposer.first_error/1` returns the raw error msg without gettext

`lib/phoenix_kit_web/components/annotation_composer.ex:272-277`

```elixir
defp first_error(%Ecto.Changeset{errors: errors}) do
  case errors do
    [{_field, {msg, _}} | _] -> msg
    _ -> nil
  end
end
```

The `{msg, opts}` shape comes from Ecto and the `opts` are interpolation values. The standard pattern is `Ecto.Changeset.traverse_errors/2` with the gettext-aware helper from `PhoenixKitWeb.ErrorHelpers` (or its modern equivalent). Otherwise pluralization keys (`%{count} items`) and locale never apply.

### #15 V115 down doesn't drop the CHECK constraint explicitly

`lib/phoenix_kit/migrations/postgres/v115.ex:109-117`

`drop_if_exists(table(...))` drops the table including its constraints — so this is functionally correct. But the up-path explicitly creates the constraint with `IF NOT EXISTS` guards, and not mirroring that in down means re-running up after down recreates the constraint just by way of table creation. Cosmetic — but pairing constraint create + drop visually pins the lifecycle.

### #16 `prefix_str("public")` returns `"public."` (V115) vs `""` (V114)

`lib/phoenix_kit/migrations/postgres/v115.ex:119-120` vs `v114.ex:138-139`

```elixir
# v115
defp prefix_str("public"), do: "public."

# v114
defp prefix_str("public"), do: ""
```

Both shapes are functionally identical at runtime (PostgreSQL routes `public.table` and `table` to the same place if `public` is on the search_path, which it always is). But the inconsistency creates a small "why is this different here" moment for future readers. Pick one (v114's empty-prefix shape is what V108 and earlier use — call this drift).

---

## NITPICK

### #17 `list_for_file_with_previews/1` walks the reply tree O(N) per annotation root

`lib/phoenix_kit/annotations/annotations.ex:107-110`

`collect_subtree/2` is a recursive walk over `children_by_parent`. For each annotation, it walks the subtree. If two annotations live on the same file and one is a reply to the other, the walk visits the same nodes twice — duplicate count. The current schema doesn't allow this (annotation-rooted comments have `parent_uuid: nil` by convention, and replies have their parent_uuid set to a non-root), so in practice this doesn't happen. Worth a defensive note in the helper.

### #18 `consume_attachments` uses `inspect/1` in user-facing flash

`lib/phoenix_kit_web/components/annotation_composer.ex:264`

Same as #4 — `"Upload failed: #{inspect(reason)}"` leaks internal struct representations. Format the reason or use a static message.

### #19 `@compile {:no_warn_undefined, ...}` lists two modules

`lib/phoenix_kit/annotations/annotations.ex:6` and `lib/phoenix_kit_web/components/annotation_composer.ex:5-9`

The composer lists both `PhoenixKitComments` and `PhoenixKit.Modules.Storage` — but the latter is **not** an optional module (it's a core PhoenixKit module). Suppressing undefined warnings on it just hides legitimate compile errors if `store_file/2` is ever renamed. Keep `PhoenixKitComments` (genuinely optional), drop `PhoenixKit.Modules.Storage`.

### #20 Hook `destroyed` callback only removes listener if `_reposition` was set

`priv/static/assets/phoenix_kit.js:1380-1385`

```javascript
destroyed() {
  if (this._reposition) {
    window.removeEventListener("resize", this._reposition);
  }
},
```

The guard is defensive but `_reposition` is always set in `mounted`, so the `if` never falls through. Cosmetic.

### #21 Etcher JS slot registration is a one-way write, no preservation of consumer slots

`priv/static/assets/phoenix_kit.js:2699`

```javascript
window.Etcher.tooltipSlots = { header, footer, body };
```

The comment claims this preserves pre-existing slots via Etcher's bootstrap `||`, but this assignment is unconditional — whatever was there is replaced. Etcher's bootstrap can't help here because PhoenixKit's JS runs as part of Etcher's loaded environment, not as a default. The pragmatic outcome (PhoenixKit owns the tooltip layout) is fine — the comment misstates the mechanism. Fix the comment.

### #22 `attachment_icon/1` returns hardcoded heroicons string-by-string

`lib/phoenix_kit_web/components/annotation_composer.ex:279-282`

```elixir
defp attachment_icon("image/" <> _), do: "hero-photo"
defp attachment_icon("video/" <> _), do: "hero-film"
defp attachment_icon("audio/" <> _), do: "hero-musical-note"
defp attachment_icon(_), do: "hero-document"
```

This pattern likely exists elsewhere in the codebase (CommentsComponent has a similar helper). Worth extracting to a shared helper. Cosmetic.

### #23 `truncate/2` reserves one char for the ellipsis

`lib/phoenix_kit_web/components/media_browser.ex:1648-1655`

```elixir
defp truncate(text, limit) when is_binary(text) do
  text = String.trim(text)
  if String.length(text) > limit do
    String.slice(text, 0, limit - 1) <> "…"
  ...
```

If `limit = 80`, the output is `slice(text, 0, 79) <> "…"` = 80 characters total. So `limit` means "max output length including ellipsis", which is fine, but the function name suggests truncating to `limit` source characters. Worth a docstring clarifying which limit is being respected.

---

## Strengths

- **Clean adapter ↔ context separation**: `EtcherAdapter` is a 77-line shim that maps Etcher's behaviour into PhoenixKit's `Annotations` context. The library coupling is one layer thick — swapping Etcher for an alternative tool would only need a new adapter.
- **Payload key whitelisting** (`@schema_keys` in the adapter): defensive against forward-compat with the JS-side payload growing new keys. The commit message even spells out the bug this prevents (`anchor_x`/`anchor_y` crashing `String.to_existing_atom`).
- **`creator_uuid` server-side override** (`creator_attrs/2`) prevents client-side spoofing of the author field — the right shape for any client-driven creation event.
- **Lifecycle composability via `send_update`**: composer ↔ MediaBrowser communicate purely via LC-to-LC `send_update`, no PubSub or parent-LV plumbing. Compositional and easy to reason about.
- **Cascade choices on FKs**: `file_uuid → :delete_all` (annotations vanish with the file), `creator_uuid → :nilify_all` (anonymous attribution survives user deletion). Both align with user expectations.
- **DB-level CHECK on `kind` enum**: catches schema/code drift the changeset's `validate_inclusion` would miss if someone added a kind only in code. Good belt-and-braces.
- **Partial index on `creator_uuid` `WHERE creator_uuid IS NOT NULL`**: avoids indexing all the `nilify_all` survivors. Right call for a column where NULL is the post-deletion default.
- **One-bulk-query loader** (`group_file_comments_by_annotation`): pulls all file comments in a single call and groups in-memory. No N+1 from the tooltip loader.
- **Comment thread = file-rooted with `metadata.annotation_uuid`**: thoughtful product decision — annotated comments show up in the file's main thread alongside non-annotated ones, no UX split. The implementation just needs the docstrings to match (see #2).

---

## Suggested follow-up scope

Tier 1 (worth fixing before next release):
- **#1** Transaction-wrap `Annotations.delete/1` (real atomicity hole)
- **#2** Sweep stale `resource_type = "annotation"` docstring claims (load-bearing accuracy)

Tier 2 (worth folding into the next sweep):
- **#5** Narrow the `rescue _` in `delete_linked_comments`
- **#6** Authorization checks on update/delete (when MediaBrowser embeds non-admin)
- **#7** `@schema_keys` source-of-truth on the schema
- **#9** `validate_geometry/1` per-kind shape check
- **#8 / #13 / #14** gettext sweep in AnnotationComposer + format_date

Tier 3 (nice-to-have, low ROI):
- **#3** Race-condition handling in finalize-vs-rollback
- **#4 / #18** Upload rollback on partial failure + non-inspect error messages
- **#10** Configurable CommentsComponent id
- **#11**, **#12**, **#15–17**, **#19–23** — cosmetics

---

## Verification

- Read all 10 changed files (lib + heex + js + mix.exs + migrations index).
- Cross-checked the `resource_type` claim against three independent docstrings and the actual `create_comment` call.
- Spot-checked `Code.ensure_loaded?` / `function_exported?` patterns against MediaBrowser's existing `PhoenixKitComments` optional-package guards.
- Did NOT run `mix test` (per project policy: `mix precommit` is the bar; integration suite needs Postgres). PR didn't include automated tests for the annotations context, adapter, or composer — worth a TODO entry for component coverage similar to AGENTS.md's existing core-component TODO.
- Did NOT run `mix precommit` against this branch — recommended as a separate step before next sweep.
