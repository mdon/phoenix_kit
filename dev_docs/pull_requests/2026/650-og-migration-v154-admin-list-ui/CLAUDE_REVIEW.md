# PR #650 — Add V154 OG migration + admin list-UI, breadcrumb and sidebar enhancements

**Author:** mdon (Max Don)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-20
**Verdict:** ✅ APPROVE — already merged; no bugs found, two low-confidence NITPICKs recorded.

---

## Summary

Bundles a new versioned migration (V154, for the upcoming `phoenix_kit_og` OpenGraph
plugin) with several unrelated admin list-UI / breadcrumb / sidebar enhancements:

1. **V154 migration** — `phoenix_kit_og_templates` (reusable OG canvas designs) and
   `phoenix_kit_og_assignments` (binds a template to a `module_key × scope_type ×
   scope_uuid` scope). `@current_version` bumps `153 → 154`.
2. **`<.bulk_actions_toolbar>` `:trailing` slot** — far-right toolbar content, for a
   view-mode switcher that should sit apart from the left-aligned sort/filter controls.
3. **`<.search_toolbar>` `loading_indicator` opt-out** — spinner shown via a
   `.phx-change-loading ~ &` sibling selector while the debounced search round-trip is
   in flight; opt-out for client-instant filters.
4. **`aria-current="page"`** on active `<.tab_item>` links/buttons.
5. **`<.page_action>`** — compact circular action button next to the breadcrumb title
   (`page_action={%{icon:, label:, navigate:}}`), threaded through
   `layout_wrapper.ex` → `admin.html.heex`.
6. **`AdminSidebarScroll` JS hook** — preserves the admin sidebar's scroll position
   across live redirects / full reloads (sessionStorage, rAF-throttled save, restore
   pre-paint, falls back to centering the active `[aria-current="page"]` link).
7. **`TableLocalSearch` JS hook** — client-instant row narrowing for
   `<.search_toolbar>` tables when the full row set is already loaded, reconciled with
   the server's authoritative patch on `updated()`.

## Files Changed (9)

| File | Change |
|---|---|
| `lib/phoenix_kit/migrations/postgres.ex` | +12/−4 — moduledoc + `@current_version` bump |
| `lib/phoenix_kit/migrations/postgres/v154.ex` | +111 — new migration |
| `lib/phoenix_kit_web/components/core/bulk_select.ex` | +6 — `:trailing` slot |
| `lib/phoenix_kit_web/components/core/table_default.ex` | +14 — `loading_indicator` opt-out |
| `lib/phoenix_kit_web/components/dashboard/tab_item.ex` | +2 — `aria-current` |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | +30/−1 — `page_action` + sidebar hook wiring |
| `lib/phoenix_kit_web/components/layouts/admin.html.heex` | +1 — thread `page_action` |
| `priv/static/assets/phoenix_kit.js` | +174 — `TableLocalSearch` + `AdminSidebarScroll` hooks |
| `test/phoenix_kit_web/components/dashboard/tab_item_test.exs` | +16 — `aria-current` test |

## Verification performed

- Read V154 against the prefix-safe-migration rules in `CLAUDE.md`: index names
  stay bare on `CREATE` (`idx_og_assignments_unique_scoped` etc., only the table name
  is `#{p}`-qualified) — correct. `uuid_generate_v7()` call is schema-qualified
  (`#{p}uuid_generate_v7()`) — correct, and the function is guaranteed present via
  `Postgres.up/1`'s `Helpers.ensure_uuid_v7_function/1` re-ensure for chains ≥ V40.
  `CREATE TABLE IF NOT EXISTS` uses an already-schema-qualified name, so no separate
  `information_schema` anchor is needed. Down migration correctly resets the version
  comment to `'153'`.
- Confirmed `phx-change` is bound to the `<input>` itself (not the wrapping `<form>`,
  which only carries `phx-submit`) in `search_toolbar/1` — so LiveView's
  `phx-change-loading` class lands on the input, matching the new spinner's
  `.phx-change-loading ~ &` sibling-selector comment. Not a bug.
- Traced `aria-current={@active && "page"}` — HEEx omits the attribute entirely when
  the value is `false` (confirmed by the new test's `refute inactive_html =~
  "aria-current"`), so this isn't accidentally rendering `aria-current="false"`.
- Read the `TableLocalSearch` and `AdminSidebarScroll` hooks in full: local-search
  correctly no-ops when `data-local-search-enabled != "true"` (avoids false "no
  matches" on a page that isn't fully loaded), and re-applies the query in
  `updated()` so client-side `hidden` classes get reconciled with the server's
  authoritative patch instead of drifting. Sidebar-scroll save/restore is
  document-level (survives live redirects without rebinding) and degrades to
  centering the active link when nothing is saved or the saved offset would leave it
  off-screen.

## NITPICKs (not fixed — low confidence / no functional impact)

### 1. `@disable_ddl_transaction true` on `V154` is likely a no-op

`lib/phoenix_kit/migrations/postgres/v154.ex:30` sets
`@disable_ddl_transaction true`, but `V154` is never itself the module registered
with `Ecto.Migrator` — the host app's generated migration file (see
`phoenix_kit.gen.migration.ex:133` / `phoenix_kit.update.ex:495`) is, and *that* file
already carries `@disable_ddl_transaction true` by template. `Ecto.Migration`
attributes like this only take effect on the module actually passed to
`Ecto.Migrator.run/4`; `V154.up/1` is called as a plain function from
`PhoenixKit.Migrations.Postgres.up/1`, so its own attribute has no effect. No other
`V*.ex` module in the chain sets this attribute. Harmless (the transaction actually
*is* disabled, just via the host template, not this line), but worth dropping in a
follow-up to avoid implying the DDL-transaction control lives here.

### 2. `canvas JSONB NOT NULL DEFAULT '{}'` — possible array/object mismatch

`v154.ex:41` defaults `canvas` to `'{}'` (empty JSON *object*). The moduledoc
describes it as "JSONB canvas *element list*" and the column comment as "reusable OG
canvas designs; JSONB `canvas` element list" — language that suggests the top-level
value may be expected to be a JSON *array* (`'[]'`) by the (external,
not-yet-in-this-repo) `phoenix_kit_og` plugin. Empty object vs. empty array are
interchangeable under `Enum`-based iteration in Elixir but not in JS (`{}.map` throws;
`Array.isArray({})` is false) if the OG editor's frontend expects an array straight
off the wire. Couldn't verify against the consuming plugin's code (not present in
this repo) — flagging for whoever builds `phoenix_kit_og` to confirm the default
matches the real `canvas` shape (e.g. `%{"elements" => [], ...}` vs. a bare list).

## Gate

`mix precommit` run at HEAD (format + compile --warnings-as-errors + credo --strict +
dialyzer) — see repo root for the run tied to this review session; no fixes were
required for this PR's changes.
