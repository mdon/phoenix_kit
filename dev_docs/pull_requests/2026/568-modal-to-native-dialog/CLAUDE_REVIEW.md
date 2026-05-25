# PR #568 — Modal-to-native-dialog: PkDialog + BulkSelect + list-UI toolkit

**Author:** mdon · **Branch:** `modal-to-native-dialog` → `main` · **State:** MERGED (`60b56bfd`)
**Reviewed:** 2026-05-25 · against `gh pr diff 568` (the change is on `origin/main`, not yet on `dev`).
**Skill:** invoked `elixir:phoenix-thinking` before review.

## Verdict

Solid, well-reasoned change. The `<dialog>` top-layer migration and the `PkDialog`
state-sync logic (`:modal` pseudo-class as truth source, refcounted scrollbar-gutter,
`_closeFromLV` echo suppression, defensive `destroyed()` decrement) are correct under
the morphdom-strips-`open` failure mode the PR set out to fix — I traced each `_sync`
branch and the close paths and found no leak or double-decrement. `BulkSelectScope`
selection survival across patches is sound (explicit `checked = true|false`, prune to
surviving uuids, idempotent `_wire` via `_pkBulkWired`). Test coverage is genuinely good.

One real i18n defect (BUG-MEDIUM) and a handful of smaller items below.

## Applied (2026-05-25, on `dev` after back-merging `origin/main`)

Both substantive findings fixed in this branch (`origin/main` merged into `dev` first,
then patched on top — `mix format` + `mix compile --warnings-as-errors` + `mix credo
--strict` all clean; dialyzer skipped as the changes are string/markup/test-only and
type-neutral):

- **BUG-MEDIUM** (gettext_noop label) — `bulk_select.ex:184` now
  `gettext("Reorder %{count} selected", count: "%{count}")`.
- **IMPROVEMENT-MEDIUM** (unnamed row `group`) — `table_default.ex` row marker is now
  `group/row`; `drag_handle_cell` uses `group-hover/row:opacity-100`. Test assertions in
  `table_default_test.exs` and the `AGENTS.md` Sortable note updated to match.

NITPICKs below left as-is (optional).

---

## BUG - MEDIUM — "Reorder N selected" toolbar label is never translated — ✅ FIXED

`lib/phoenix_kit_web/components/core/bulk_select.ex` (`bulk_actions_toolbar/1`):

```elixir
|> assign(:reorder_selected_label, gettext_noop("Reorder %{count} selected"))
```

`gettext_noop/1` **returns the msgid unchanged — it does not translate**. Its only job is
to make the string visible to `mix gettext.extract`. The standard pattern (see
`lib/phoenix_kit_web/live/modules.ex:95` `_register_module_translations/0`) is: register
with `gettext_noop`, then translate the value at runtime with `gettext(label)`.

Here the noop result is written straight into `data-bulk-label-selected` and the
`BulkSelectScope` JS only does `String.replace("%{count}", …)` — nothing ever translates
it. So in every non-English locale (ru/et are 100% locales) the button renders the English
"Reorder N selected", while its sibling `gettext("Reorder all")` *is* translated — an
inconsistent, half-translated toolbar.

**Fix** — translate at render time while preserving the placeholder for the JS:

```elixir
|> assign(:reorder_selected_label, gettext("Reorder %{count} selected", count: "%{count}"))
```

`gettext/2` interpolates `%{count}` with the literal string `"%{count}"`, yielding the
*translated* template with the placeholder intact for client-side substitution. (Same
treatment applies to any future `data-bulk-text-template` strings.)

---

## IMPROVEMENT - MEDIUM — always-on unnamed `group` on every row clobbers nested `group-hover:` — ✅ FIXED

`lib/phoenix_kit_web/components/core/table_default.ex` (`table_default_row/1`) now adds an
unnamed `"group"` to **every** row. The drag-handle reveal needs it, but Tailwind's plain
`group`/`group-hover:` is ancestor-scoped: `group-hover:x` compiles to
`.group:hover .group-hover\:x`, so it fires for **any** `.group` ancestor.

Concrete in-repo collision: the sortable header cell wraps its label in its own unnamed
`group` (`table_default.ex:661`) with `group-hover:opacity-70` on the sort chevron
(`:688`). That cell renders inside a `<.table_default_row>` (see the moduledoc example,
lines 14–18), which now also carries `group`. Result: hovering **anywhere on the header
row** now brightens the sort chevron, not just hovering the sort label. Any external
consumer using bare `group-hover:` inside a row inherits the same surprise.

**Recommendation** — scope the row marker to a named group and have `drag_handle_cell`
read the same name:

```elixir
# row:    class={["group/row", ...]}
# handle: "opacity-0 group-hover/row:opacity-100 ..."
```

Named groups don't intercept descendants' unnamed `group-hover:`, so the change becomes
non-invasive to existing tables. Low blast radius today (cosmetic), but it's a latent
footgun the moment a consumer nests a plain group.

---

## NITPICK — `aria-labelledby` points at a non-existent element when there's no title

`lib/phoenix_kit_web/components/core/modal.ex`:

```heex
aria-labelledby={"#{@resolved_id}-title"}
```

This is now rendered unconditionally, but the `<h3 id="…-title">` is still gated on
`@title != []`. A modal opened without a `:title` slot therefore advertises
`aria-labelledby` to an id that doesn't exist (dangling reference — AT may announce
nothing). The previous code guarded with `@id && …`. Either gate the attribute on the
title slot, or fall back to `aria-label`. (`reorder_modal` always passes a title, so it's
unaffected — this is for generic callers.)

## NITPICK — `PkCheckboxIndeterminate` hook is dead within phoenix_kit

`priv/static/assets/phoenix_kit.js` adds the `PkCheckboxIndeterminate` hook, but no
component in this PR emits `phx-hook="PkCheckboxIndeterminate"` / `data-indeterminate`
(`rg` finds zero consumers in `lib/`). The bulk header's indeterminate state is driven
directly by `BulkSelectScope._sync` (`header.indeterminate = …`). Harmless, but it reads
as accidental dead code — add a one-line comment that it's exposed for external consumers
(phoenix_kit_projects et al.), or drop it until something uses it.

## NITPICK — JS placeholder replace only hits the first occurrence

In `_sync`, both `data-bulk-text-template` and the label flip use
`String.prototype.replace("%{count}", …)`, which replaces a single occurrence. Some
locales legitimately repeat the count. Use a global replace
(`.replaceAll("%{count}", …)` or `/…/g`) to be locale-safe. Pairs naturally with the
BUG-MEDIUM fix above.

## NITPICK — test naming says "PkScope" not "BulkSelectScope"

`test/phoenix_kit_web/components/core/bulk_select_test.exs` — the first `test` is named
`"renders div with PkScope hook + data-bulk-total"`. The hook is `BulkSelectScope`
(the assertion is correct; only the test name is stale). Cosmetic.

---

## Notes / non-blocking

- **Instant-open contract is load-bearing.** When `data-bulk-opens-dialog` opens the
  `<dialog>` client-side, the consumer LV **must** flip its `@show_*` assign to `true` in
  response to the pushed event. If it doesn't, the next *unrelated* LV patch hits
  `_sync`'s `!wantOpen && isOpenForBrowser` branch and force-closes the just-opened modal.
  This is documented in the toolbar attr doc, but it's the kind of contract that bites a
  consumer who wires the button before the handler. The `keep_in_dom` docstring's
  id-collision warning is good; consider adding the "you must flip @show" half there too.

- **`reorder_modal` radios persist across opens** (kept-in-DOM form is never re-rendered).
  A prior strategy stays checked on reopen. `required` still blocks empty submits, so this
  is UX-only, not a correctness issue — flagging in case a reset-on-open is wanted.

- **Older-browser degradation is explicit and acceptable.** `isDialogOpenInBrowser` falls
  back to `el.open` when `:modal` throws (pre-2022 engines), which reintroduces the
  morphdom-strip bug on those engines only. Documented; fine given support targets.

## Verified clean

- `PkDialog._sync` branch matrix, `_onClose`/`_onCancel`/`_onClick`/`destroyed` close paths,
  refcount (`_PkDialogOpenCount`) increment/decrement — no leak, no double-decrement.
- `BulkSelectScope` selection persistence across `apply_reorder` / `load_more` / sort,
  node-reuse safety (explicit `checked` both ways), listener idempotency.
- `auth.ex` single-read of `prefixless_primary?()`; `annotation.ex` `:creator_uuid`
  exclusion from the adapter whitelist — both correct.
- `sort_selector` race-free wiring (select → `sort_by` only, arrow → `sort_dir` only),
  atom/string normalization, empty/nil/bad-row options handling.

## Open

- BUG-MEDIUM (gettext_noop label) — ✅ fixed in this branch.
- IMPROVEMENT-MEDIUM (named `group/row`) — ✅ fixed in this branch.
- NITPICKs — left optional, not applied.
