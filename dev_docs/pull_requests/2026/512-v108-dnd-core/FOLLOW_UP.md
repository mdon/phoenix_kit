# PR #512 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code (post-merge).

## Fixed (pre-existing)

The reviewer's six findings (5 NITPICKs + 1 LOW) were all addressed
between merge and this triage:

- ~~**NITPICK #1: `:reorder_scope` key transformation isn't
  documented.** `<.table_default>`'s `:reorder_scope` attr now
  includes the camelCase round-trip explanation in the doc string
  (`lib/phoenix_kit_web/components/core/table_default.ex:106`):
  *"Keys are lowercased and dasherized for the DOM attr; the JS
  hook sends them back to LV as camelCase, so an Elixir key
  `:category_uuid` arrives in the LV handler payload as
  `\"categoryUuid\"`."*~~
- ~~**NITPICK #2: `<.table_default>` footer DOM shape changes for
  non-DnD callers.** Informational note for the `card_actions` slot
  wrapper change (`justify-end` → `justify-between` + `ml-auto`).
  Visual output unchanged via `ml-auto`; no in-tree CSS selectors
  affected. No code change required.~~
- ~~**NITPICK #3: `:on_reorder` only wires the card view; table-view's
  tbody is the consumer's job.** `:on_reorder` attr doc now explains
  the asymmetry (`table_default.ex:101`): *"The table-view's tbody is
  owned by the inner_block — wire that side separately so desktop
  users get the same DnD as mobile."*~~
- ~~**NITPICK #4: `__invoke_dynamic_children_for_test__/3` is a public
  API.** Reviewer's own verdict: "current trade-off is fine — keeps
  the test fast and DB-free." `@doc false` keeps it out of generated
  docs; the strict-reading concern is acknowledged but not blocking.~~
- ~~**NITPICK #5: `<.draggable_list>` strips `data-id` when
  `@draggable=false`.** Fixed: `data-id={@item_id_fn.(item)}` is now
  emitted unconditionally (`lib/phoenix_kit_web/components/core/draggable_list.ex:120`)
  — only the `class` and `phx-hook` are gated on `@draggable`. Doc
  updated (`:82`): *"`data-id` is still emitted on each item so
  click-to-select handlers and test selectors work in both modes."*~~
- ~~**IMPROVEMENT-LOW: V108 sort stability before any drag.**
  Downstream consumer concern. Catalogue's item lists already use
  `order_by: [asc: :position, asc: :name]` as the deterministic
  tiebreaker pre-reorder (`phoenix_kit_catalogue/lib/phoenix_kit_catalogue/catalogue.ex`
  multiple sites). Entities' downstream wiring follows the same
  shape. No core change needed.~~

## Skipped

None.

## Files touched

None in this triage — every finding was addressed pre-existing.

## Verification

`<.table_default>` and `<.draggable_list>` doc + behavior changes
confirmed via direct file inspection. Component test coverage is
still pending the workspace TODO (`AGENTS.md` "Component test
coverage for `phoenix_kit_web/components/core/`" section) — same
state as the reviewer noted.

## Open

None.
