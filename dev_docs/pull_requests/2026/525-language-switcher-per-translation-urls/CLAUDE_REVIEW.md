# PR #525 — Add `:per_translation_urls` attr to core LanguageSwitcher (and DnD bundle)

**Author:** @mdon
**Branch:** `feat/language-switcher-host-integration` ← `dev`
**Merged:** 2026-05-08T21:55:28Z (`289d90c3`)
**Diff:** +354 / -21 (4 files, 1+ commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/525

## Verdict

**APPROVE** with one IMPROVEMENT-MEDIUM around scope: the PR title
and body advertise the LanguageSwitcher attr only, but the diff also
includes two substantial unrelated changes (`table_default.ex` drag
handle scoping; `phoenix_kit.js` sortable flash + TR cell-width
preservation + handle support). All three changes are correct in
isolation; the bundling makes the review surface harder to scope.

The headline change is the cleanest part:

- `:per_translation_urls` attr on three switcher variants (dropdown,
  buttons, inline) — defaults to `nil`.
- New private `resolve_url/3` falls back to the historical
  `generate_base_code_url/2` on miss / nil / empty list.
- `entry_base_code/1` + `entry_url/1` accept atom-keyed and
  string-keyed entries.
- `DialectMapper.extract_base/1` normalizes full dialect codes
  (`"en-US"`) to base codes (`"en"`) on lookup.

The tests pin all six relevant cases (atom-keyed, string-keyed,
dialect normalization, per-language fallback, nil pass-through,
empty pass-through, missing attr default).

The bundled DnD work is a real improvement: drag handle scoping
(`.pk-drag-handle`) means clicking text or buttons inside a card no
longer triggers drag; the `<tr>` cell-width preservation closes a
known SortableJS-with-`forceFallback` quirk; the `sortable:flash`
event gives users visual confirmation after a server-confirmed
reorder. But none of it is in the PR body.

## What changed

### Headline (LanguageSwitcher)

| Layer | Change |
|---|---|
| `language_switcher.ex` | New `attr :per_translation_urls, :list, default: nil` on `language_switcher_dropdown`, `language_switcher_buttons`, `language_switcher_inline` |
| `language_switcher.ex` | New private `resolve_url/3` — 4 clauses (nil, [], list-with-binary-base-code, catch-all) all falling back to `generate_base_code_url/2` on miss |
| `language_switcher.ex` | New `entry_base_code/1` + `entry_url/1` helpers — accept atom-keyed `%{code: ..., url: ...}` or string-keyed `%{"code" => ..., "url" => ...}` |
| `language_switcher.ex` | 8 call-site replacements: `generate_base_code_url(base, path)` → `resolve_url(base, path, @per_translation_urls)` |
| Tests | New `language_switcher_test.exs` (7 tests) — first test file for this component |

### Bundled (DnD / sortable; not in PR body)

| Layer | Change |
|---|---|
| `table_default.ex` | New `data-sortable-handle=".pk-drag-handle"` attribute when `@on_reorder` is set |
| `table_default.ex` | Card surface no longer gets `cursor-grab` / `active:cursor-grabbing` classes — only the `.pk-drag-handle` element does |
| `table_default.ex` | Footer-row layout: `card-actions justify-between` → `flex flex-wrap items-center gap-2`; removes the empty `<span>` placeholder |
| `phoenix_kit.js` | New `sortable:flash` event handler — applies `pk-sortable-flash-{ok,err}` for ~1.2s, idempotent via reflow |
| `phoenix_kit.js` | New `<tr>` cell-width preservation via `onChoose` / `onUnchoose` — locks `<td>` widths before drag preview renders, restores on drop |
| `phoenix_kit.js` | `data-sortable-handle` attr → SortableJS's `handle` option |
| `phoenix_kit.js` | `moved_id` always included in `reorder_items` payload (previously only on cross-container moves) |

## Findings

### IMPROVEMENT - MEDIUM — DnD bundle is undocumented in the PR body

The PR title is "Add :per_translation_urls attr to core LanguageSwitcher",
and the body discusses only the LanguageSwitcher changes. The 200+
line DnD work in `table_default.ex` and `phoenix_kit.js` is
unmentioned.

This matters for two reasons:

1. **Audit trail.** Future maintainers searching `git log
   --oneline` for "drag handle" or "sortable flash" won't find this
   PR. They'll have to walk file blame instead.
2. **Reviewer focus.** Bundle reviews compress: if a reviewer
   mentally allocates "language switcher PR" and skims, they may
   not realize the same diff touches the SortableJS hook and
   `<tr>`-width-preservation in non-trivial ways.

The DnD changes are *good* — drag-handle scoping is a UX upgrade,
the cell-width preservation closes a real SortableJS quirk, the
flash event is a clean server→client signal. They each deserve to
land. They just deserve their own PR (or at least their own section
in the body).

Two paths forward:

- **Retroactively annotate the merge commit** with a note that
  it bundled DnD improvements; or
- **Write a `dev_docs/pull_requests/2026/525-…/FOLLOW_UP.md`**
  enumerating the DnD changes so the audit trail is searchable.

**Where:** Entire `table_default.ex` and `phoenix_kit.js` diffs
absent from PR body

### IMPROVEMENT - LOW — `resolve_url/3` is invoked twice per language `<a>` tag

`lib/phoenix_kit_web/components/core/language_switcher.ex:230-235`:

```heex
<a
  href={resolve_url(language["base_code"], @current_path, @per_translation_urls)}
  phx-click="phoenix_kit_set_locale"
  phx-value-locale={language["base_code"]}
  phx-value-url={resolve_url(language["base_code"], @current_path, @per_translation_urls)}
  ...
```

`resolve_url/3` runs once for `href` and once for `phx-value-url`.
The function isn't free — it does an `Enum.find/2` over
`per_translation_urls` and a `DialectMapper.extract_base/1` per
candidate entry. For a typical 4-language site, that's 4-8
list-walk operations per language render, doubled.

The render-time cost is small (microseconds) but the duplication is
also a subtle correctness risk: any future change to
`resolve_url/3`'s contract (caching, side effects, randomness) would
need to be applied at both call sites consistently.

The fix is a render-time `let`:

```heex
<%= for language <- @languages do %>
  <% url = resolve_url(language["base_code"], @current_path, @per_translation_urls) %>
  <a href={url} phx-value-url={url} ...>
```

…or equivalent via `assigns` augmentation in `prepare_dropdown_assigns/1`.
Two of the three render variants (`buttons`, `inline`) have the same
duplication. Three call sites total → six `resolve_url` invocations
→ three. Minor but easy.

**Where:** `lib/phoenix_kit_web/components/core/language_switcher.ex:230-235,
298-303, 439-441, 562-564`

### NITPICK — `entry_base_code/1` clause for atom-keyed input is the documented "publishing's typical shape"; the moduledoc could surface the convention

`lib/phoenix_kit_web/components/core/language_switcher.ex:781-784`:

```elixir
defp entry_base_code(%{code: code}) when is_binary(code), do: DialectMapper.extract_base(code)

defp entry_base_code(%{"code" => code}) when is_binary(code),
  do: DialectMapper.extract_base(code)
```

Two clauses for atom and string keys. The `attr :per_translation_urls`
moduledoc says:

> Each entry is `%{code: <display_code>, url: <full_url>}`.

…which only describes the atom-keyed shape. A reader passing the
string-keyed shape (e.g. from a controller assign that came from
JSON) won't know the component accepts both unless they read
`entry_base_code/1`'s source. A one-line addition to the attr doc:

> Both atom-keyed (`%{code: ..., url: ...}`) and string-keyed
> (`%{"code" => ..., "url" => ...}`) entries are accepted.

…would make the contract self-documenting.

**Where:** `lib/phoenix_kit_web/components/core/language_switcher.ex:114-126`

### NITPICK — `resolve_url/3`'s "no entry → fall back to default" is correct but the "entry has nil URL → fall back" branch is unobvious

`lib/phoenix_kit_web/components/core/language_switcher.ex:768-775`:

```elixir
defp resolve_url(base_code, current_path, per_translation_urls)
     when is_list(per_translation_urls) and is_binary(base_code) do
  case Enum.find(per_translation_urls, fn entry ->
         entry_base_code(entry) == base_code
       end) do
    nil -> generate_base_code_url(base_code, current_path)
    entry -> entry_url(entry) || generate_base_code_url(base_code, current_path)
  end
end
```

The `entry_url(entry) || generate_base_code_url(...)` branch handles
"the publishing module returned an entry but its `:url` field is
`nil`." Today this happens when `phoenix_kit_publishing` builds the
list defensively for a draft post that doesn't have a URL yet. Fine.

But the fallback is silent — the rendered `<a>` for that language
gets the locale-rewrite URL, even though the entry exists. A user
clicking it would land on a different page than they expected. A
no-op `Logger.debug/2` flagging the fallback would help operators
diagnose the "language switcher links to the wrong place" bug if
it ever surfaces. Not worth a `:warning`-level log because draft
posts are a normal occurrence.

**Where:** `lib/phoenix_kit_web/components/core/language_switcher.ex:763-774`

### NITPICK — `data-sortable-handle` value depends on `@on_reorder` truthiness

`lib/phoenix_kit_web/components/core/table_default.ex:230`:

```heex
data-sortable-handle={if @on_reorder, do: ".pk-drag-handle"}
```

`@on_reorder` is the boolean / function attr that decides whether
this card supports drag-to-reorder. The `data-sortable-handle`
attribute is conditional on it. Fine, but the JS hook *also*
guards on `@on_reorder` (it sets `phx-hook="SortableGrid"` only
when `@on_reorder` is set). So the conditional emission is
defense-in-depth — when SortableJS isn't initialized (no hook),
the `data-sortable-handle` value doesn't matter.

The current shape is correct. The minor critique is that
`data-sortable-handle` is emitted *only* when `@on_reorder` is
truthy, which means the attribute either renders as a string or
not at all — never as `data-sortable-handle=""`. Phoenix.HTML
handles this correctly via `:if`-style truthiness. Worth knowing
that future tests asserting "data-sortable-handle is present on
the card" need to know it'll be absent in the no-reorder case.

**Where:** `lib/phoenix_kit_web/components/core/table_default.ex:230`

### NITPICK — `sortable:flash` event has no in-PR test coverage

The new `sortable:flash` LV→client event is wired in
`phoenix_kit.js:213-243` and depends on the host LV pushing
`{uuid: "...", status: "ok" | "error"}`. There's no test in this
PR that:

1. Asserts the LV pushes `sortable:flash` after `reorder_items`
   succeeds / fails.
2. Asserts the JS hook applies the right class for each status.

The first is a server-side test that lives in the consumer's LV
test suite, not in core. The second would need a JS unit test or
LiveView integration test that simulates the `pushEvent`.

Neither is realistic to add in this PR's scope. Worth flagging that
the contract (status: "ok" | "error") is defined entirely by
informal convention in the JS hook — a typo on the server side
("OK" vs "ok") would silently fall through to the err class. A
two-line `if` defending against unknown status:

```javascript
var cls = payload.status === "ok"
            ? "pk-sortable-flash-ok"
            : payload.status === "error"
              ? "pk-sortable-flash-err"
              : null;
if (!cls) return;
```

…would make the contract explicit at the boundary.

**Where:** `priv/static/assets/phoenix_kit.js:218-244`

## What's good

- **`resolve_url/3` is the right Elixir shape.** Four function-head
  clauses pattern matching on `nil`, `[]`, `is_list/1` with
  `is_binary/1` on `base_code`, and the catch-all. No nested case,
  no `cond`, no `if`. Each branch falls back to
  `generate_base_code_url/2` so a misshapen input never produces a
  `nil` URL — exactly the elixir-thinking pattern from the skill
  prompt.
- **`DialectMapper.extract_base/1` for both atom-keyed and
  string-keyed input.** The two `entry_base_code/1` clauses + the
  one in `entry_url/1` cover both shapes without complecting the
  match logic. A future format (e.g. `{code: ..., url: ...}` tuple)
  would slot in as a fourth clause without touching the rest.
- **Test file is the first one for `LanguageSwitcher`.** Good
  precedent — pins seven contract corners (atom-keyed, string-keyed,
  full dialect normalization, per-language fallback, nil
  pass-through, empty pass-through, missing attr default). The next
  test in this file should be quick to add.
- **Backwards-compatibility honesty.** The PR body's explicit
  "When the assign is `nil` (non-publishing pages), the switcher
  falls back to its existing default — fully backward compatible"
  matches the test for `per_translation_urls={nil}`. Caller code
  that doesn't pass the attr at all gets the defstruct default
  (`nil`) and the same fallback. ✓
- **The DnD bundle's drag-handle scoping is the right UX.** Pre-PR,
  the entire card was `cursor-grab` and any pointer-down on text /
  links / buttons could trigger a drag. Post-PR, only the `<.icon
  name="hero-bars-3" />` footer handle initiates drag. Clicking a
  card to expand it (or focus a button inside it) no longer fights
  with SortableJS.
- **`<tr>` cell-width preservation is a real fix.** The
  `onChoose` / `onUnchoose` snapshot is exactly the right
  workaround for SortableJS's `forceFallback: true` +
  `fallbackOnBody: true` combo — when the dragged `<tr>` is
  cloned to `document.body`, it loses its `<table>` ancestor and
  every `<td>` collapses to content width. Snapshot before drag,
  restore after. Standard pattern.
- **`sortable:flash` server→client signal.** Idempotent via the
  `void item.offsetWidth` reflow trigger; querying *all*
  `[data-id]` elements (not just the closest) handles the
  table-view + card-view dual-render correctly. The CSS
  `::after` overlay (rather than `background-color` animation)
  avoids the "card briefly becomes transparent and bleeds page
  bg through" artifact that a naïve `background-color` keyframe
  would produce.
- **Coordination notice.** Like #524, this PR's body explicitly
  documents what happens when the matching publishing PR isn't
  also installed — backward-compatible default, no host changes
  needed. Hosts can install in either order.
