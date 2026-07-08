# PR #623 — V139 dashboards config migration, viewport connect-param installer step, daisyUI modal-gutter fix

- **Author:** mdon (`mdon:main`)
- **Merged:** 2026-07-08 (merge `a14fb847`)
- **Reviewer:** Claude (Opus 4.8)
- **Verdict:** Ship-ready. No correctness bugs. One documentation-accuracy fix applied; two nitpicks recorded.

## Scope

| File | What |
|---|---|
| `lib/phoenix_kit/migrations/postgres/v139.ex` | New: JSONB `config` column on `phoenix_kit_dashboards` |
| `lib/phoenix_kit/migrations/postgres.ex` | `@current_version` 138 → 139 |
| `lib/phoenix_kit/install/js_integration.ex` | New installer step: inject `viewport_width` LiveSocket connect param |
| `test/phoenix_kit/install/js_integration_test.exs` | 13 cases pinning the `inject_viewport_param/1` transform |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` + `layouts/root.html.heex` | daisyUI 5.0.x modal scrollbar-gutter counter-rule |
| `AGENTS.md` | TODO documenting removal of the counter-rule after daisyUI upgrade |

---

## Findings

### IMPROVEMENT - MEDIUM — `postgres.ex` version-history block not updated for V139 *(fixed)*

`@current_version` was bumped to `139`, but the human-readable migration history in
`postgres.ex` still carried `### V138 - CRM v1 interaction tracker ⚡ LATEST` with no
`### V139` entry. In a library where migration versioning is load-bearing, the stale
`⚡ LATEST` marker is actively misleading — a maintainer reading the block would
conclude 138 is the head.

**Fix applied:** added a `### V139 - Dashboard \`config\` column ⚡ LATEST` entry and
moved the `⚡ LATEST` marker off V138, matching the style of the surrounding entries.

*(Aside: `### V137` is also absent from the block — a pre-existing gap, not introduced
here, left as-is.)*

### NITPICK — V139 moduledoc vs. PR description drift *(not fixed)*

`v139.ex`'s moduledoc describes `config` as "the layout mode (grid vs free) and
pixel-mode zoom"; the PR body describes it as "type fixed at creation, home tier,
per-tier customized markers." The column is generic `JSONB` read/written whole, so the
mismatch is functionally irrelevant — left as the author's intent. Recorded only so the
drift is on the record.

---

## Verified NON-issues (checked, no action needed)

These are the traps a shallower review would flag or miss; each was chased down.

1. **`ALTER TABLE phoenix_kit_dashboards` is safe even without the dashboards module
   installed.** My first concern was that `ADD COLUMN IF NOT EXISTS` only guards the
   *column*, not the *table* — so on a host lacking the module, it would raise
   `relation "phoenix_kit_dashboards" does not exist`. **Not a bug:** core migration
   **V133** (`v133.ex`) creates the table via `CREATE TABLE IF NOT EXISTS`, and V133
   runs before V139. Core owns *all* DDL under versioned migrations; modules carry only
   code. The table is guaranteed present when V139 runs.

2. **Migration dispatch resolves `V139`.** `execute_migration_steps/4` builds
   `Module.concat([__MODULE__, "V#{pad_idx}"])` with
   `pad_idx = String.pad_leading("139", 2, "0")` = `"139"` →
   `PhoenixKit.Migrations.Postgres.V139`, which exists. Version marker (`up` → `'139'`,
   `down` → `'138'`) matches the V133/V138 pattern exactly.

3. **Both install and update flows call the viewport injection.** `add_js_integration`
   (install, `phoenix_kit.install.ex:124`) → `ensure_module_js_integration` →
   `add_viewport_param_to_app_js`; and `phoenix_kit.update.ex:383` calls
   `ensure_module_js_integration` directly. PR's "install + update" claim holds.

4. **The `inject_viewport_param/1` transform cannot corrupt host `app.js`.** The
   blanked-string/comment output (`blank_strings_and_comments/1`) is used **only** to
   count brace depth; the actual rewrite slices the *original* `rest` via `binary_part`,
   so imperfect blanking can only skew depth away from 1 → fails closed to `:manual`,
   never a wrong edit. Every ambiguous shape (nested-brace params, closure-form params,
   comment-bearing params, params beyond the 500-byte window, no LiveSocket, block/line
   commented anchors) resolves to `:manual` (notice), not a mangled file. Offsets are
   byte-consistent throughout (`:binary.matches`, `Regex.scan(return: :index)`,
   `binary_part`) — the multibyte-prefix test locks this in.

5. **Nested `params:` inside a hook body is correctly skipped.** `top_level_params/1`
   requires `brace_depth == 1` relative to the LiveSocket options `{`; a
   `this.pushEvent("load", {params: {page: 1}})` sits at depth ≥ 2 → `nil` (keep
   scanning) → the real top-level params is patched. Pinned by the "nested params" and
   `"}}}"`-string-fake tests.

6. **Idempotency is by KEY form (`~r/viewport_width\s*:/`), not prose.** A `// TODO: add
   viewport_width someday` comment (no colon) does not fake `:already`; a real
   `viewport_width:` anywhere does. A contrived `// viewport_width: ...` comment *would*
   false-`:already` and skip injection — but that only withholds the optimization, never
   corrupts, consistent with the module's fail-closed philosophy. Acceptable.

7. **daisyUI counter-rule is a documented cosmetic trade-off, not a regression.**
   Unlayered `:root:has(.modal-open, …) { scrollbar-gutter: auto }` beats daisyUI's
   layered `@layer base` rule regardless of stylesheet order (correct cascade). The
   ~15px reflow on scrollable pages is called out in the rule comment and in the
   `AGENTS.md` removal-TODO. Duplicated into both the admin `LayoutWrapper` and the core
   root layout deliberately, so coverage holds whether or not the host uses PhoenixKit's
   root layout.

---

## Tests

13/13 new cases in `js_integration_test.exs` — they exercise the public transform
(`inject_viewport_param/1`) rather than the private helpers, so refactors of the
depth/anchor internals won't break them. Coverage matches every attack shape in the
finding above. No test added for the migration or CSS, consistent with repo convention
(V13x migrations have no dedicated tests; `ensure_current/2` covers migration wiring).

## Gate

`mix precommit` (format + compile --warnings-as-errors + credo --strict + dialyzer) — see chat for result.
