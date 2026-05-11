# PR #528 — Add sort+search helpers to TableDefault (follow-up)

**Author:** @timujinne
**Branch:** `timujinne:dev` → `BeamLabEU:dev`
**Status:** MERGED (2026-05-10, commit `d0cc931f`)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/528

> **Note:** A first-pass review for this PR exists under
> `dev_docs/pull_requests/2026/529-table-default-sort-search-helpers/CLAUDE_REVIEW.md`
> (folder name was off-by-one — the PR was actually #528). That review's
> two IMPROVEMENT-MEDIUM items (`phx-change` double-bind on the form
> variant and missing `phx-target` on `<form>`) were fixed in `dfc91238`
> before merge, with two new regression tests. This document is a
> **follow-up review on the merged code** focused on concrete
> improvements we can land ourselves in a follow-up PR.
>
> Recommend leaving the misnamed `529-...` folder in place — it is
> historically correct for the moment when the review was written
> (PR # was speculative pre-open) and renaming would lose the audit
> trail.

## Verdict

**MERGED — three follow-up improvements worth doing.** The core
shape is good; what remains is a pre-existing latent crash in a file
this PR touched, an accessibility gap on the new component, and a
redundant `on_submit` setting at the call sites that doubles the
`search` event on Enter.

## Outstanding items (newly identified)

### BUG - HIGH (pre-existing, surfaced by touched file) — `live_sessions` pagination crashes the LV

`lib/phoenix_kit_web/live/users/live_sessions.html.heex:292-294`:

```heex
<button
  phx-click="goto_page"
  phx-value-page={page_num}
  ...
>
```

`lib/phoenix_kit_web/live/users/live_sessions.ex` defines event
handlers for `"search"`, `"filter_by"`, `"toggle_sort"`,
`"toggle_auto_refresh"`, `"refresh_now"` — **no `"goto_page"`,
no `"change_page"`**. Clicking any pagination button on
`/admin/users/live-sessions` raises `FunctionClauseError` in
`handle_event/3` and crashes the LiveView (auto-reconnects, but the
click is lost and the Logger error fires).

The sibling `users.ex` page uses `"change_page"` (`users.ex:121`),
so the established convention in this codebase is `change_page`.

**Origin:** pre-existing — predates this PR. But this PR touched
`live_sessions.html.heex` (header replacement + search toolbar) and
the file as merged still ships the broken pagination block. Worth
opportunistically fixing in the follow-up since we're back in this
file.

**Why HIGH:** the page is reachable, the button is rendered any time
`@total_pages > 1` (i.e. > 20 active sessions, plausible on real
deployments), and clicking it crashes the LV.

**How to apply:**
1. Rename `phx-click="goto_page"` → `phx-click="change_page"` in
   `live_sessions.html.heex:293`.
2. Add the matching handler in `live_sessions.ex` (mirroring
   `users.ex:121`):
   ```elixir
   def handle_event("change_page", %{"page" => page}, socket) do
     {:noreply,
      socket
      |> assign(:page, String.to_integer(page))
      |> load_sessions()}
   end
   ```

### IMPROVEMENT - MEDIUM — `sort_header_cell/1` lacks `aria-sort`

`lib/phoenix_kit_web/components/core/table_default.ex:438-467` —
the active column shows a chevron icon, but the `<th>` has no
`aria-sort` attribute. Screen readers can see a "button" inside a
table header but cannot announce that the column is sorted, in which
direction, or that other columns are sortable but inactive.

WAI-ARIA spec: `aria-sort` on `<th>` takes
`"ascending" | "descending" | "none" | "other"`.

**Why MEDIUM, not BUG:** the visual chevron conveys state to sighted
users; the component is functional. But a11y on admin tables is
worth getting right at the primitive layer once, rather than retrofit
across every consumer.

**How to apply:** in `sort_header_cell/1`, derive
`aria-sort` from `@sort` and `@field`:

```heex
<th
  class={@class}
  aria-sort={
    cond do
      is_nil(@sort) -> nil
      @sort.by == @field and @sort.dir == :asc -> "ascending"
      @sort.by == @field and @sort.dir == :desc -> "descending"
      true -> "none"
    end
  }
  {@rest}
>
```

Phoenix.Component drops `nil` attrs, so the inert-label branch
(no `sort`) emits a clean `<th>` unchanged.

Add a regression test asserting
`aria-sort="ascending"` / `"descending"` / `"none"` on the three
states.

### IMPROVEMENT - MEDIUM — Redundant `on_submit="search"` doubles work on Enter

`lib/phoenix_kit_web/live/users/live_sessions.html.heex:106-110` and
`lib/phoenix_kit_web/live/users/users.html.heex:85-89` both pass
`on_submit="search"`, which puts the input inside a `<form>` with
`phx-submit="search"`. The input itself has
`phx-change="search" phx-debounce="300"`.

Pressing Enter in the input:
1. Form submit fires `"search"` immediately with the current value.
2. The pending `phx-change` debounce is **not** cancelled by submit
   — it fires 300ms later with the same payload.

End result: `"search"` runs twice for one Enter press. Idempotent on
state, but doubles `Presence.list_active_sessions/0` and the post-
filter sort/pagination work for a debounce window's worth.

**Why MEDIUM, not NITPICK:** the function `search_toolbar/1` is
designed for both modes (debounced live search OR form-submit
search), but the in-tree consumers picked **both at once**. Either
the wrap-in-form or the change-debounce alone is correct. Both is
strictly more work for no benefit.

**How to apply:** either

- Drop `on_submit="search"` from both call sites. Search becomes
  pure debounced live search; Enter is a no-op (which matches typical
  filter UX — there's no separate "search button" anywhere in the
  UI). Simplest.
- Or, less likely, keep `on_submit` and introduce an
  `on_submit_only`-style flag to suppress the input's `phx-change`
  in the form variant.

Recommend the first.

### NITPICK — `flip_dir/1` catch-all is too lax

`live_sessions.ex:271-272`:

```elixir
defp flip_dir(:asc), do: :desc
defp flip_dir(_), do: :asc
```

The `_` clause silently accepts anything (e.g. a stray `nil`,
`"asc"` string, `:foo`). The current call site only ever passes
`:asc`/`:desc`, but the laxness will mask bugs the day someone
threads an unintended value through. Tightening costs nothing:

```elixir
defp flip_dir(:asc), do: :desc
defp flip_dir(:desc), do: :asc
```

Let it crash on bad input rather than silently coerce.

### NITPICK — `align` attr is silently dropped on the inert-label branch

`sort_header_cell/1` applies `justify-end` / `justify-center` to the
**button** inside `<th>`. When `@sort` is nil the inner block
renders without a wrapper, so `align` has no visible effect.

A header table can have a mix of sortable and non-sortable columns
sharing the same `align`; the current behaviour means the inert
columns silently render left-aligned no matter what `align` says.

**How to apply:** lift the alignment to the `<th class>` so it
applies in both branches:

```heex
<th class={[
  @align == :right && "text-right",
  @align == :center && "text-center",
  @class
]} ...>
```

…and drop `justify-end w-full` / `justify-center w-full` from the
button (or keep them — the `<th>` text alignment cascades through
just fine, and we get inert-branch alignment for free).

### NITPICK — HEEX duplication between form/div branches in `search_toolbar/1`

Already noted in the prior review (`529-...` folder). Still standing.
The `<.icon>` + `<input>` block (~7 lines) is copy-pasted in both
arms of `<%= if @on_submit do %>`. An inner private partial
(`render_search_input/1`) called from both branches would DRY this
without losing the wrapper-only conditional clarity. Worth doing
when next touching the file; not worth its own PR.

### NITPICK — Test coverage gaps for `name`, `debounce`, `event` default

Already noted in the prior review. Tracked under the standing
`test/phoenix_kit_web/components/core/` coverage TODO in `CLAUDE.md`.

## What I deliberately did **not** flag

- **`load_sessions`/`load_stats` called in `mount/3`.** Iron Law
  violation in spirit (mount runs twice on first connect), but the
  data source is `PhoenixKit.Admin.Presence` (in-memory ETS), not
  a Postgres call. Fixing it means moving the calls to
  `handle_params/3` and adjusting the assigns lifecycle —
  pre-existing, unrelated to this PR's scope.
- **Refresh-timer doubling on rapid auto-refresh toggle.**
  `schedule_refresh/0` doesn't cancel pending timers; toggling OFF
  then ON within the 5s window leaks an extra timer per cycle.
  Pre-existing, observable but minor (every leaked timer eventually
  fires once and dies because there's no reschedule loop unless
  `auto_refresh: true` at fire-time, so the leak is bounded by toggle
  count, not unbounded). Out of scope.
- **`mix.exs @version` and `CHANGELOG.md`.** Verified untouched per
  the project's version/CHANGELOG ownership rule.
- **Gettext catalog drift.** Same disposition as the prior review:
  separate commit, accepted as a long-overdue resync.

## Suggested follow-up PR scope

A single tight follow-up could land:

1. Fix `live_sessions` pagination crash (BUG-HIGH above) — rename
   `goto_page` → `change_page`, add handler.
2. Add `aria-sort` to `sort_header_cell/1` + 3-state regression
   test.
3. Drop `on_submit="search"` from both call sites.
4. Tighten `flip_dir/1` to explicit `:desc` clause.
5. (Optional) Lift `align` to `<th class>` in `sort_header_cell/1`.

Items 1-4 are ~20 lines of code + ~10 lines of test, low-risk. Item
5 is a behavioural change to a public component contract — fine but
worth a separate commit.
