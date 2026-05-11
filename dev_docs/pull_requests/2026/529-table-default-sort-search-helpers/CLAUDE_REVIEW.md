# PR #529 — Add sort+search helpers to TableDefault

**Author:** @timujeen
**Branch:** `timujinne:dev` ← `BeamLabEU:dev`
**Status:** Open (this review)
**Diff:** +5322 / -5313 across 15 files (3 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/529

## Verdict

**APPROVE with NITPICKs.**

> **Update 2026-05-09:** Both IMPROVEMENT-MEDIUM items below were
> addressed in commit `dfc91238` ("Fix search_toolbar form variant
> event bindings") with two regression tests. Test count: 13 → 15.
> NITPICKs left as-is (behaviour change, chevron variant, coverage
> gaps, branch duplication) — folded into the standing `core/`
> test-coverage TODO from `CLAUDE.md`.

Three commits, two of them clean cleanups
(.gitignore + gettext resync), one feature commit that adds two
opt-in stateless components to `TableDefault` and migrates two admin
pages to use them — including a real UX bug fix on
`/admin/users` (search input was hitting the server on every
keystroke).

The feature commit was already through a two-stage internal review
that caught and fixed two bugs (a dead `assign_new` placeholder
default and a missing `mix gettext.extract --merge`). Both are
correctly addressed in the final state. The NITPICKs below are
ergonomic, not correctness; merge is fine as-is.

## What changed

| Layer | File(s) | Change |
|---|---|---|
| Components | `lib/phoenix_kit_web/components/core/table_default.ex` | +109 lines. Two new opt-in components: `sort_header_cell/1` (clickable `<th>` with chevron-up-mini/down-mini, inert when `sort: nil`), `search_toolbar/1` (daisyUI `input-sm` with `hero-magnifying-glass` and `phx-debounce` default 300ms, optional form wrap when `on_submit` is set). |
| State refactor | `lib/phoenix_kit_web/live/users/live_sessions.ex` | Collapsed `:sort_by` + `:sort_order` assigns into single `:sort = %{by, dir}`. Renamed event `"sort_by"` → `"toggle_sort"` with `"by"` param. Three inline private fns: `parse_sort_by/1` (whitelist), `toggle_sort/2`, `flip_dir/1`. |
| Template migration | `lib/phoenix_kit_web/live/users/live_sessions.html.heex` | Two ad-hoc `<th><button>...<chevron></button></th>` blocks (~30 lines each) replaced with `<.sort_header_cell field={:type} sort={@sort}>` and `<.sort_header_cell field={:connected_at} sort={@sort}>`. Old search form replaced with `<.search_toolbar>`. |
| Bug fix | `lib/phoenix_kit_web/live/users/users.html.heex` | Bare `<form phx-submit phx-change><input>` (no `phx-debounce` — every keystroke hit the server) replaced with `<.search_toolbar value={...} on_submit="search">`. |
| Tests | `test/phoenix_kit_web/components/core/table_default_test.exs` | 13 tests in a new directory (closes part of the standing `core/` test-coverage TODO from `CLAUDE.md`). |
| i18n | `priv/gettext/{default.pot, en, et, ru, de, es, fr, it, pl}/...` | Standalone commit — `mix gettext.extract --merge` with our `Search...` msgid. Surfaces ~75 unrelated new msgids and ~76 obsolete deletions accumulated from prior commits where extract wasn't run. Author explicitly opted to accept the resync rather than split (PR-thread context). |
| Hygiene | `.gitignore` | Standalone commit — adds `/priv/static/assets/vendor/` to keep `mix phoenix_kit.install` runs against `/app` itself from leaving an outdated copy of the source JS in tree. |

## Findings

### IMPROVEMENT - MEDIUM — `search_toolbar/1` form variant double-binds `phx-change`

`table_default.ex:491,501` — when `on_submit` is set, the form
variant places `phx-change={@on_change}` on **both** the `<form>`
and the inner `<input>`:

```heex
<form phx-change={@on_change} phx-submit={@on_submit} ...>
  <.icon ... />
  <input ... phx-change={@on_change} phx-debounce={@debounce} ... />
</form>
```

Phoenix LiveView fires `phx-change` once per element binding. The
form-level binding is redundant when the input has its own — and
they don't carry the same payload either: form-level submits the
whole form data, input-level submits just the input. With identical
events bound to both, you can in practice end up with the same
`"search"` event firing twice in quick succession (input on
keystroke, then form on the same change), which usually just costs
double work but can race against `phx-debounce`.

**Why a MEDIUM, not a blocker:** the input fires first and the form
follows synchronously; the duplicated event payload is a superset of
the input's, so the LV's `handle_event/3` clause matches both with
the same `"search" => value`. No incorrect state. But it doubles
server work and is conspicuously redundant.

**How to apply:** drop `phx-change` from the `<form>` element. Keep
it only on `<input>`. The form is there for `phx-submit` on Enter,
nothing more.

### IMPROVEMENT - MEDIUM — `phx-target` not propagated to `<form>`

`table_default.ex:489-506` — when caller passes
`<.search_toolbar target="#my-component">`, the `phx-target` lands on
the `<input>` (so `phx-change` retargets correctly) but **not** on
the `<form>` (so `phx-submit` does not). When the toolbar is rendered
inside a `LiveComponent`, pressing Enter fires the submit event
against the parent LV instead of the component, breaking the
encapsulation.

**Why a MEDIUM, not a blocker:** no in-tree consumer (`live_sessions`,
`users`) uses `target` — they're root LVs, not LiveComponents. So
the bug is latent, not active. But the moment someone embeds
`<.search_toolbar>` in a LiveComponent context with `on_submit` set,
this surfaces.

**How to apply:** add `phx-target={@target}` to the `<form>` element
alongside the `phx-submit` binding.

### NITPICK — Behaviour change on first click of a new column

Before (`live_sessions.ex` old):

```elixir
{field_atom, :desc}  # first click on a NEW column → descending
```

After (`live_sessions.ex` new):

```elixir
defp toggle_sort(_, new_by), do: %{by: new_by, dir: :asc}
```

Spec asks for `:asc` on column switch (matches the new component's
implicit contract — chevron-up first, click again to flip to
chevron-down). Migration is spec-correct, but users who had muscle
memory for "clicking 'Type' shows descending first" will see the
opposite. Two columns, low-traffic admin page — fine. Worth
mentioning in a CHANGELOG entry when one is written by the
maintainer.

### NITPICK — Chevron icon size/style change

Old: `hero-chevron-up` / `hero-chevron-down` (24px outline).
New: `hero-chevron-up-mini` / `hero-chevron-down-mini` (20px solid).

Visual difference is small but real. The `-mini` variant is the
correct call for a header indicator (more compact, less visual
weight than the action icons elsewhere in the page). Flagging only
because the diff is silent about it; future migrations of other
sortable headers should follow the same convention.

### NITPICK — Test coverage gaps

`test/phoenix_kit_web/components/core/table_default_test.exs` is a
solid first pass, but a few attrs are declared and not asserted:

| Attr | Component | Why it matters |
|---|---|---|
| `target` | `search_toolbar/1` | Related to the IMPROVEMENT-MEDIUM above; a regression test would surface the `<form>` issue. |
| `name` | `search_toolbar/1` | Default `"search"` is asserted only indirectly via `phx-change="search"`. Custom name (`name="filter"`) untested. |
| `debounce` | `search_toolbar/1` | Default 300ms asserted, custom value (e.g. `debounce={150}`) untested. |
| `event` (default) | `sort_header_cell/1` | First test happens to verify `phx-click="toggle_sort"`, but as a side effect — no explicit "event defaults to toggle_sort when omitted" case. |

Not a merge blocker — the existing 13 tests cover the load-bearing
contract. Fold these into the standing `core/` test-coverage sweep
tracked in `CLAUDE.md`.

### NITPICK — HEEX duplication between form/div branches

`table_default.ex:489-521` — the `<input>` markup (~12 lines) is
copy-pasted into both the `<%= if @on_submit do %>` and `<% else %>`
branches, with the only difference being the surrounding wrapper
(`<form ...>` vs `<div ...>`). EEx makes wrapper-only conditionals
awkward (no easy way to conditionally pick the wrapper while keeping
the children DRY without a private helper component), so the current
shape is readable and idiomatic. Could be tightened later by
extracting a private `render_search_input/1` partial; not worth a
fix in this PR.

## Things I deliberately did **not** flag

- **Gettext catalog drift (~10000 lines).** Author explicitly chose
  to accept the full `mix gettext.extract --merge` output as a
  separate commit (`a7c1d35b`) rather than surgically isolate just
  the `Search...` hunk. Net effect is a long-overdue catalog cleanup;
  the 76 deletions are orphan strings from the extracted
  `customer_service` module, the 75 additions are msgids from prior
  source-tree commits where extract wasn't run. Out of scope for
  code-correctness review.
- **`String.to_existing_atom` removed in favour of whitelist.**
  The old `live_sessions.ex` code was already safe (the relevant
  atoms were guaranteed to exist via the LV's own assigns). The new
  `parse_sort_by/1` is pattern-match on strings and falls back to
  `:connected_at` for unknown — equally safe, slightly more explicit.
  Parity, not a security improvement.
- **`assign(assigns, :placeholder, ...)` not `assign_new`.** Earlier
  internal review caught a dead `assign_new` (it never fires when
  `attr :placeholder, default: nil` pre-fills the key). The fix in
  the final state uses `assigns.placeholder || dgettext(...)`, which
  is the right pattern for functional components. Regression test
  `"default placeholder uses dgettext fallback"` is in place.
- **`mix.exs @version` and `CHANGELOG.md`.** Verified untouched per
  the project's `Version + CHANGELOG ownership` rule
  (`CLAUDE.local.md`).
- **`<th>` element semantics.** `sort_header_cell/1` always renders
  `<th>` (never `<td>`), per spec. Correct for table headers.
- **Active-column styling.** Chevron-only, no font-weight or color
  shift, per spec. Correct.
- **`phx-target={nil}` on `sort_header_cell/1`.** Phoenix.Component
  auto-omits attributes with `nil` values, so the resulting `<button>`
  has no spurious `phx-target=""`. Verified empirically.
- **CSRF / XSS.** `value` and `placeholder` flow through Phoenix's
  HTML-escaping. `phx-change` events carry LiveView's built-in CSRF
  token. No new attack surface.
- **`.gitignore` rule scope.** `/priv/static/assets/vendor/` is
  anchored to the repo root via the leading `/`, so it only ignores
  the path inside PhoenixKit's own tree. Parent apps (decor_3d_print,
  hydroforce) are unaffected — their own `.gitignore` either covers
  this or they actively track their `vendor/` copy. Correct scope.

## Summary

Net + ~140 lines of feature/test/hygiene wrapped in ~10000 lines of
mechanical i18n drift. Two NITPICK-bordering-MEDIUM ergonomic items
in `search_toolbar/1`'s form variant (`phx-change` double-bind,
`phx-target` not propagating to `<form>`) are worth fixing in a
follow-up, but neither breaks any current consumer. Everything else
is clean. Approve.
