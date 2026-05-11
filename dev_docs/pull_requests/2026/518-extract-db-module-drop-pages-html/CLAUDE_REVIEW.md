# PR #518 — Extract DB module to phoenix_kit_db; drop dead `PagesHTML`

**Author:** @mdon
**Branch:** `feat/extract-db-module` ← `dev`
**Merged:** 2026-05-06T17:58:25Z (`4e4e5123`)
**Diff:** +4 / -2631 (16 files, 4 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/518

## Verdict

**APPROVE.** Two unrelated cleanups that are each surgically clean,
bundled into one PR:

1. **DB module extraction** — drops `PhoenixKit.Modules.DB` from
   `internal_modules/0`, removes the eight files that backed it, drops
   the three hand-registered `live` declarations from `integration.ex`,
   removes the hardcoded module card from `modules.html.heex`, updates
   tests. The new package (`phoenix_kit_db`) handles its own routes via
   `admin_tabs/0` once installed — same external-module pattern as
   hello_world, document_creator, etc.
2. **`PagesHTML` removal** — the module had no controller, no routes,
   no callers, and the embedded markdown-pages feature was superseded
   by the publishing module. The `embed_templates "pages_html/*"`
   directive plus `show.html.heex` plus the integration.ex docstring
   were a phantom feature.

The verification in the PR body is thorough: `ast-grep` for both
removals, `rg` for path strings, three `mix test` runs for stability,
zero credo issues. The 4 V107 failures are pre-existing on `dev`
(verified independently per the PR body).

Findings below are all NITPICKs / housekeeping.

## What changed

| Removed | Reason |
|---|---|
| `lib/modules/db/db.ex` (644 lines) | Extracted to `phoenix_kit_db` package |
| `lib/modules/db/listener.ex` (227 lines) | Same — Postgrex.Notifications GenServer goes with the module |
| `lib/modules/db/web/{activity,index,show}.{ex,html.heex}` (~1470 lines) | Same — admin LiveViews |
| `PhoenixKit.Modules.DB` from `module_registry.ex:internal_modules/0` | List entry |
| Three `live "/admin/db…"` declarations | `integration.ex:455-462` — auto-discovery picks them up via `admin_tabs/0` post-install |
| DB module card | `modules.html.heex:582-654` — autogen via `<.module_card>` based on `admin_tabs/0` |
| Module list test entries | `module_registry_test.exs`, `module_test.exs` — count assertions `>= 8` → `>= 7` |
| `lib/phoenix_kit_web/controllers/pages_html.ex` (8 lines) | Dead module — no callers |
| `lib/phoenix_kit_web/controllers/pages_html/show.html.heex` (191 lines) | Dead template |
| Docstring block in `integration.ex:71-76` | "Public pages routes" — described a feature that wasn't wired |

| Added | Reason |
|---|---|
| `dev_docs/guides/2026-02-24-module-system-guide.md` table reflow | Move `db` from Internal → External examples; cite `phoenix_kit_db/` as the small-footprint plugin reference between hello_world and document_creator |

## Findings

### NITPICK — `auth.ex:998` `{"db", "/admin/db"}` is the only living core reference to a now-extracted module

```elixir
# lib/phoenix_kit_web/users/auth.ex:983-1007
@admin_path_priority [
  ...
  {"jobs", "/admin/jobs"},
  {"db", "/admin/db"},          # ← entry for an extracted module
  {"publishing", "/admin/publishing"},
  ...
]
```

The PR body acknowledges this and explains the convention ("same shape
as the also-external `phoenix_kit_ai` entry"), so this is intentional —
the `best_available_admin_path/1` redirect-target list keeps an entry
even when the module isn't currently in the dep tree, so that *if* a
host installs `phoenix_kit_db` later, `db`-permissioned users with no
other admin access redirect to `/admin/db` instead of `/`.

The trade-off is a one-way coupling: adding a new external module
that wants this redirect priority requires a core PR to update this
list, which contradicts the "auto-discovery via `admin_tabs/0`" model
the rest of the PR validates. Worth a follow-up to make this list
itself auto-discovered (pull `path` + `permission` from each module's
top-level admin_tab entry, sort by `priority`). Out of scope for this
PR — would expand the surface considerably and isn't a blocker for
extraction. Fine to ship as-is.

**Where:** `lib/phoenix_kit_web/users/auth.ex:983-1007`

### NITPICK — Test count assertions remain hardcoded after the bump

`test/phoenix_kit/module_registry_test.exs` updated three count
assertions:

```elixir
assert length(metadata) >= 8     # → >= 7
assert length(keys)     >= 8     # → >= 7
assert map_size(checks) >= 8     # → >= 7
```

The accompanying comment on `:18-19` explains the intent: *"Verify
known modules are present rather than asserting a hardcoded count, so
this test doesn't break when modules are extracted or added."* Yet
the file then asserts `>= 7` after this PR's extraction. The right
shape would be `>= length(@all_internal_modules)` (or similar), so
the next extraction bumps both the list and the assertion together
without a manual count-tweak. The comment is correctly aspirational;
the implementation didn't quite match. Cosmetic.

**Where:** `test/phoenix_kit/module_registry_test.exs:152, 173, 196`

### NITPICK — V107 test failures are noise on a branch that's clean

The PR body documents:

> `mix test`: 1055 tests, 4 failures — all in `V107Test` (AI endpoint
> `integration_uuid` backfill); pre-existing on `dev` before this branch
> (verified by stashing my changes and re-running). Unrelated to this PR.

Worth a separate ticket — V107's test was acknowledged in PR #511's
review (NITPICK #7: "tests replicate the migration SQL verbatim"
because the helpers can't run outside a `Migrator` runner) but a
4-failure test isn't healthy state on `dev`. Independent of this PR;
flagging for the audit trail.

### NITPICK — `module-system-guide.md` reflow assumes ascending plugin scale

The reordered table:

```
| **External examples** | |
| phoenix_kit_hello_world/         | Minimal plugin template |
| phoenix_kit_db/                  | Supervisor child + admin tabs |
| phoenix_kit_document_creator/    | Full-featured plugin (13 tabs, …) |
```

Reads "small → medium → large." Will the next extracted module slot
correctly into this ordering, or does the table grow to 20 rows
sorted by no clear criterion? If the intent is "examples by
complexity," noting that explicitly above the table would let future
contributors pick the right insertion point. Not load-bearing.

**Where:** `dev_docs/guides/2026-02-24-module-system-guide.md:1557-1565`

### NITPICK — Untracked 0-byte `lib/phoenix_kit_web/controllers/pages_html.ex` in working tree

Outside the PR diff, but flagging because it's the same path the PR
deleted: the local working tree has an untracked 0-byte file at
`lib/phoenix_kit_web/controllers/pages_html.ex`. Probably an editor /
IDE recreated the empty file when navigating to a stale tab; harmless
but worth removing from the workspace so it doesn't confuse the next
review or accidentally get re-added in a future commit. Not a finding
against the PR itself.

## What's good

- **Two-stage commit split.** Commit `6b5badb4` is the surgical
  extraction (drop module + delete files). `3a859a25` updates tests.
  `c42fb797` updates the guide. `559f86df` is the standalone
  PagesHTML cleanup. Each commit is reviewable in isolation; the
  extraction is reversible by `git revert 6b5badb4` without
  collateral damage to the test or guide updates.
- **`ast-grep` verification.** PR body shows
  `ast-grep --lang elixir --pattern 'PhoenixKit.Modules.DB' lib/ test/`
  returning zero — that's structural verification (catches references
  the module names in macros, comments-with-code, etc.) which a plain
  `rg` would miss. Good practice that I'd like to see become a habit
  for extraction PRs.
- **PagesHTML triage was honest.** The PR body doesn't say "rewriting
  pages support to be better" — it says "this thing was never wired
  up." Confirmed by the deletion: `pages_html.ex` had `use PhoenixKitWeb,
  :html` plus `embed_templates "pages_html/*"` and a single
  `show.html.heex`, but no controller declared it as a render target.
  The integration.ex docstring described routes that no
  corresponding `live`/`get`/`post` macro registered. Dead code, not
  a regression risk.
- **Module-card autogen.** Removing the hardcoded DB block from
  `modules.html.heex:582-654` rather than leaving it as a "shows up
  if module is installed" guard is the right call. The
  `<.module_card>` autogen path now drives the page; if the external
  module is later installed, its tab + card render via the standard
  `admin_tabs/0` discovery rather than a parallel hand-coded path.
- **Test stability.** Three `mix test` runs in the PR body, same 4
  failures each time. That rules out flaky-due-to-extraction (which
  would be the worst case — extraction breaks isolation and tests
  start interfering across runs).
