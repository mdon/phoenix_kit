# PR #522 — Add gettext support for Dashboard sidebar labels

**Author:** @timujinne
**Branch:** `feature/dashboard-i18n` ← `dev`
**Merged:** 2026-05-08T21:12:40Z (`8f83fe54`)
**Diff:** +1739 / -26 (15 files, 4 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/522

## Verdict

**APPROVE.** A textbook backwards-compatible API extension. Three
mechanically clean changes, plus two large docs:

1. **`PhoenixKit.Dashboard.{Tab, Group}` gain two optional fields:**
   `gettext_backend` (module, defaults `nil`) and `gettext_domain`
   (string, defaults `"default"`). Three resolver functions
   (`Tab.localized_label/1`, `Tab.localized_tooltip/1`,
   `Group.localized_label/1`) call `Gettext.dgettext/3` when a backend
   is set and fall back to the raw label otherwise.

2. **14 render sites in `Sidebar`, `AdminSidebar`, `TabItem`** swap
   `tab.label` → `Tab.localized_label(tab)` (and the equivalent for
   tooltips and group labels). Mechanically uniform, no shape changes.

3. **Hot-reload safety via `Map.get/2`** rather than struct pattern
   matching. An old-shape `%Tab{}` cached in ETS or `:persistent_term`
   from before the upgrade — missing both new keys — flows through
   the resolver as if `gettext_backend` were `nil`, returning the raw
   label rather than raising `FunctionClauseError`. The test suite
   pins this with explicit `Map.delete/2` before-and-after structs.

The 43 new dashboard tests are well-targeted: raw-label fallback,
nil-label dividers, `ru`-locale resolution, missing-translation
fallback, `new/1` keyword + map round-trip, divider/group-header
gettext support, and the hot-reload stale-struct case. `async: false`
is correctly used because `Gettext.put_locale/2` is process state.

Findings below are nitpicks. The PR shape itself is right.

## What changed

| Layer | Change |
|---|---|
| `dashboard/tab.ex` | `gettext_backend` (`module() \| nil`), `gettext_domain` (`String.t()`) added to `defstruct` + `@type`; `Tab.new/1` round-trips both via `get_attr/2`; `divider/1` and `group_header/1` accept the same opts |
| `dashboard/tab.ex` | `localized_label/1`, `localized_tooltip/1` — `Map.get`-based lookup, `Gettext.dgettext(backend, domain, msgid)` when backend present, raw fallback otherwise |
| `dashboard/group.ex` | Same shape — two new fields + `localized_label/1` |
| `components/dashboard/sidebar.ex` | 5 sites — group label render guard, group label render, more_menu tab, mobile parent, mobile subtab |
| `components/dashboard/admin_sidebar.ex` | 2 sites — group label guard + render |
| `components/dashboard/tab_item.ex` | 7 sites — 5 labels + 2 tooltips |
| Tests | 43 new cases across `tab_test.exs`, `group_test.exs`, `tab_item_test.exs`; explicit `Map.delete` regression for stale-struct hot-reload |
| Docs | `guides/per-module-i18n.md` (532 lines, ExDoc-shipped); `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md` (442 lines, internal procedure) |

## Findings

### IMPROVEMENT - LOW — `gettext_domain` field reads "always present, sometimes default"; could collapse to a tagged union

The current shape has two coupled fields:

- `gettext_backend: module() | nil` — opt-in flag
- `gettext_domain: String.t()` — `"default"` always, or a custom string

99% of callers will set `gettext_backend: SomeBackend` and accept the
default `"default"` domain. The `gettext_domain` field exists in the
struct for every Tab in every registered module, even when no
translation is configured. Two alternatives that compress this:

1. **Single field**, accept either a module or a `{module, domain}`
   tuple:

   ```elixir
   gettext: PhoenixKit.MyApp.Gettext
   gettext: {PhoenixKit.MyApp.Gettext, "navigation"}
   ```

   Resolver matches:

   ```elixir
   case Map.get(tab, :gettext) do
     nil -> tab.label
     {backend, domain} -> Gettext.dgettext(backend, domain, tab.label)
     backend -> Gettext.dgettext(backend, "default", tab.label)
   end
   ```

2. **Inline-only** — accept just `gettext_backend`, hardcode
   `"default"` in the resolver, and tell the (very rare) custom-domain
   caller to use multiple Gettext modules.

Either compresses the struct by one field per Tab. Not load-bearing —
the current shape is fine — but worth considering before too many
modules adopt the API and the migration cost grows.

**Where:** `lib/phoenix_kit/dashboard/tab.ex:165-185`,
`lib/phoenix_kit/dashboard/group.ex:14-30`

### IMPROVEMENT - LOW — `localized_label/1` always builds a domain string per call

`lib/phoenix_kit/dashboard/tab.ex:329-336`:

```elixir
def localized_label(%__MODULE__{label: label} = tab) do
  case Map.get(tab, :gettext_backend) do
    nil ->
      label

    backend ->
      domain = Map.get(tab, :gettext_domain) || "default"
      Gettext.dgettext(backend, domain, label)
  end
end
```

The `|| "default"` fallback fires when:

1. The struct was created before the field existed (hot-reload case
   — the `Map.get` returns `nil`, the `||` substitutes
   `"default"`). ✓
2. A caller deliberately set `gettext_domain: nil` (unlikely; defstruct
   defaults to `"default"`).

For the 99% common case (`gettext_domain: "default"`), the `Map.get`
returns `"default"` and the `||` is a no-op. Cost: two map lookups
per render call instead of one struct field access.

A micro-optimization (and clarity gain) would be to assume the field
exists for every "current-shape" struct and only do the `Map.get`
fallback in the resolver:

```elixir
def localized_label(%__MODULE__{label: label, gettext_domain: domain} = tab) do
  case Map.get(tab, :gettext_backend) do
    nil -> label
    backend -> Gettext.dgettext(backend, domain, label)
  end
end
```

But that's exactly the pattern the hot-reload safety was designed to
avoid — `%__MODULE__{... :gettext_domain ...}` would raise
`KeyError` on a stale-shape struct missing the field. The current
implementation is correct *because* it's defensive. Worth a one-line
moduledoc note to flag the trade-off so the next reviewer doesn't
"optimize" the safety away.

**Where:** `lib/phoenix_kit/dashboard/tab.ex:325-336, 348-358`,
`lib/phoenix_kit/dashboard/group.ex:43-55`

### IMPROVEMENT - LOW — `gettext_backend` stored as a module atom is brittle on rename / removal

A registered Tab struct contains the literal module atom (e.g.,
`PhoenixKitNewsletters.Gettext`). If the parent app removes
`phoenix_kit_newsletters` from its deps without restarting:

1. The Tab struct remains cached in `:persistent_term` /
   ETS (depending on Registry implementation).
2. Sidebar render calls `Tab.localized_label(tab)`.
3. `Gettext.dgettext(stale_atom, "default", "Label")` is called on
   an unloaded module.
4. Gettext's behaviour for an unloaded backend module: typically
   returns the msgid (graceful), but in some cases raises
   `UndefinedFunctionError` if it tries to call
   `stale_atom.__gettext__/1`.

The current `localized_label/1` doesn't `try/rescue` this case. In
practice, `Code.ensure_loaded?(stale_atom)` would be a one-line
defensive guard:

```elixir
case Map.get(tab, :gettext_backend) do
  nil -> label
  backend ->
    if Code.ensure_loaded?(backend) do
      Gettext.dgettext(backend, ..., label)
    else
      label
    end
end
```

Or alternatively, the Registry could `Gettext.put_locale` once at
boot and let the resolver crash if the backend is stale (loud
failure beats silent miss). Either is reasonable. Fine to defer
until a real "removed-module" incident makes the priority obvious.

**Where:** `lib/phoenix_kit/dashboard/tab.ex:325-358`

### NITPICK — Test couples to `PhoenixKitWeb.Gettext`'s actual `ru` catalogue

`test/phoenix_kit/dashboard/tab_test.exs:14-18`:

```elixir
@backend PhoenixKitWeb.Gettext
@known_msgid "Dashboard"
@known_ru_translation "Панель управления"
```

If the `ru/LC_MESSAGES/default.po` catalogue is regenerated and the
"Dashboard" → "Панель управления" pairing changes (translation
tweak, msgid rename, etc.), this test breaks even though the
`localized_label/1` contract is still correct.

A more isolating shape: define a test-only Gettext backend (similar
to how the new auth_test.exs in PR #521 uses `Module.create/3`) with
its own minimal `.po` catalogue, and assert against *those* pairings.
Then the test is decoupled from product copy.

Not a blocker — the current copy is stable enough — but a follow-up
worth doing before the test count grows.

**Where:** `test/phoenix_kit/dashboard/tab_test.exs:14-18`

### NITPICK — `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md` is 442 lines bundled in this PR

The internal procedure doc is high-quality (named gotchas,
step-by-step commands, conditional CI skip, version bump rules) but
it's also tightly coupled to a *separate* operational rollout that
this PR doesn't itself perform. Bundling it makes the PR
+1739 / -26 across 15 files, when the API + render-site changes
alone would be a much smaller PR.

Two PRs would have been:

1. **API + render sites + tests** (~+800 lines, surgical, easy review)
2. **Migration procedure doc** (~+440 lines, separate review pass)

Each shippable independently. The bundled form works because the doc
is read-only and harmless if the API isn't yet adopted; it just
inflates the diff. This is a workspace-style preference rather than
a defect. Calling it out for the audit trail.

**Where:** `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md`
(entire file)

### NITPICK — Public `guides/per-module-i18n.md` doesn't note the hot-reload safety

The public guide explains the API setup but doesn't surface the
`Map.get/2`-based hot-reload safety as a contract. A module author
upgrading their parent app might assume that pattern matching
`%Tab{gettext_backend: backend, gettext_domain: domain}` is fine —
which it is for *their* tabs (always the new shape) but not for any
generic handler iterating over `Registry.all_admin_tabs/0` that
might encounter stale structs from another module.

A 3-line moduledoc note in `guides/per-module-i18n.md` under
"Common pitfalls":

> **Don't pattern-match on `gettext_backend` / `gettext_domain` from a
> generic Tab handler.** Use `Map.get/2` so old-shape structs cached
> across upgrades don't raise `KeyError`. The library's own resolvers
> (`Tab.localized_label/1` etc.) already do this for you.

…would close the gap.

**Where:** `guides/per-module-i18n.md:485-532`

### NITPICK — PhoenixKit's own admin tabs not migrated (intentional but creates a window of partial coverage)

The PR body acknowledges:

> PhoenixKit's own admin/user tabs are NOT migrated in this PR. Their
> labels still render raw English. Migrating them is straightforward
> (add `gettext_backend: PhoenixKitWeb.Gettext` to ~19 registrations
> across `admin_tabs.ex`, `registry.ex`, `jobs.ex`) and is intentionally
> left for a follow-up so this PR stays scoped to the API.

This is the right scope decision *for the API*, but it means a parent
app that adopts the new pattern will see their plugin tabs translated
while PhoenixKit's own core tabs still render English. End-user
experience: a half-translated sidebar.

The follow-up PR (touching ~19 sites, all of the same shape:
`gettext_backend: PhoenixKitWeb.Gettext`) would be a small mechanical
diff. Worth pinning a target version in the CHANGELOG entry once the
maintainer writes one — "1.8.x: API. 1.8.x+1: core tab migration."

**Where:** `lib/phoenix_kit_web/admin_tabs.ex` and friends (untouched
by this PR)

## What's good

- **Hot-reload safety is the right shape.** `Map.get/2` instead of
  pattern matching is the elixir-thinking-aligned choice for the
  "struct shape may have evolved across hot-reload" case. The
  regression test at `tab_test.exs` (`Map.delete(:gettext_backend)`)
  pins it explicitly — a future "let's pattern match for clarity"
  refactor would fail this test loudly.
- **`Gettext.dgettext/3` not `Gettext.gettext/2`.** Using the
  domain-aware variant from day one means a future caller wanting
  domain-segregated catalogues (`navigation.po` separate from
  `default.po`) doesn't need an API change. ✓
- **Backwards-compat at every boundary.**
  - `defstruct` defaults: `gettext_backend: nil`, `gettext_domain: "default"`
  - `Tab.new/1` round-trips both with optional access
  - Resolver: `nil` backend → raw label
  - Sidebar render: works with both old and new struct shapes
  - Existing tests (without `gettext_backend`): green without modification
- **Test set covers the contract corners.** Raw fallback, nil label,
  nil tooltip, divider tabs, ru-locale resolution, missing-translation
  fallback, `new/1` map+keyword round-trip, divider gettext support,
  group-header gettext support, hot-reload stale-struct case. The
  "old struct missing keys" case is the kind of thing easy to ship
  without testing — the explicit test here is exactly the right
  defensive coverage.
- **Mechanical render-site swap.** 14 sites, all of the form
  `tab.label` → `Tab.localized_label(tab)`. No semantic changes, no
  conditional logic, just routing every render through the resolver.
  Easy to spot-check, hard to subtly break.
- **`async: false` honesty.** `Gettext.put_locale/2` is process-state;
  `async: false` + `setup do ... on_exit(fn -> ... end)` is the
  correct shape. The PR doesn't try to fake-out the locale via test
  helpers or environment variables.
- **The "non-goal" callouts are explicit.** No version bump, no
  CHANGELOG, core tabs not migrated — each reasoned and clearly
  labelled. Matches the workspace's "CHANGELOG ownership: maintainer
  writes" rule from AGENTS.md. ✓
- **Operational procedure doc is unusually thorough.** The
  `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md`
  surfaces every gotcha hit during the Newsletters pilot (the
  `skip-worktree` trap, the `path:` override etiquette, the
  CI-skip pattern for graceful degradation) so the next package
  migration doesn't re-discover them. This is exactly the kind of
  artifact that pays off when the next module author sits down and
  doesn't have to re-derive the workflow from scratch.
