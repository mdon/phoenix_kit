# New core components: Chart, StatusDot, ConnectAccountButton (+ stat_card value_color)

**Branch:** `feat/nordswitch-core-components`
**Origin:** extracted from NordSwitch (nordswitch.eu) — the first app to dogfood
these; its hand-rolled versions are running in production-dev today.
**Status:** implementation done, deliberately untested — this doc is the
handoff for the AI/dev doing tests, review and polish.

## What was added

### 1. `PhoenixKitWeb.Components.Core.Chart` (new)

Server-rendered SVG chart primitives, zero JS, theme-aware via
`currentColor`:

- `area_chart/1` — line/area chart over `{x, y}` number tuples; `step`
  attr for interval data (right-open steps — each y holds until the
  next x); optional `marker_x` dashed vertical marker ("now" line);
  auto or explicit domains; `:empty` slot.
- `sparkline/1` — minimal polyline over a list of numbers.
- `bar_chart/1` — simple vertical bars over `%{label, value}` maps.

Rationale: core (and the dashboards module) had **no chart primitives at
all**; every consumer either hand-rolls SVG or pulls a JS library. These
are LiveView-native: assigns change → SVG re-renders.

Real-world usage reference (NordSwitch): a 96-slot day-ahead electricity
price curve with a "now" marker, updating every 15 min over PubSub, and
a 12-hour price sparkline; both currently hand-rolled in
`NordswitchWeb.Charts` and ready to be swapped to these components.

### 2. `PhoenixKitWeb.Components.Core.StatusDot` (new)

`status_dot/1` — tiny semantic colored dot + optional label + optional
`pulse` (ping animation). Boolean convenience `up={bool}` for the
online/offline case, or explicit `variant` atom. Fills the gap between
nothing and the domain-specific badges in `Badge` (role/user/code).

### 3. `PhoenixKitWeb.Components.Core.ConnectAccountButton` (new)

`connect_account_button/1` — the OAuth-popup "Connect your X account"
pattern (window.open named popup; provider consent; callback closes
popup + reloads opener). Distinct from `OAuthProvider` (app sign-in);
this is for the Integrations system's third-party account linking.
The expected callback-page script contract is documented in the
moduledoc.

### 4. `stat_card` extension (modified, backward compatible)

New optional `value_color` attr (CSS color string) applied as inline
style to the value element in both compact and full layouts — for
values whose color IS information (NordSwitch: spot price colored
green→red by cheapness). Default nil = no change for existing callers.

### 5. Registration

All three new modules imported in `phoenix_kit_web.ex` `core_components`
block.

## Notes / decisions for the reviewer

- **Charts are numeric-domain only** on purpose: no DateTime handling in
  the component; callers map time → number. Keeps the API tiny and the
  component future-proof. If a datetime axis helper is wanted later, it
  should be a separate wrapper, not a widening of this API.
- `preserveAspectRatio="none"` + `vector-effect="non-scaling-stroke"` is
  the stretch model: the SVG fills its container, strokes stay crisp.
  Containers control size via normal CSS (`h-48 w-full`).
- Gradient stops use `stop-color="currentColor"` — verify on all
  supported browsers (works in Chrome/FF/Safari current; that claim is
  untested here).
- `area_chart` step mode extends the last slot to the x-domain's right
  edge — intended for interval data; check the non-step + explicit
  x_domain combinations.
- Suggested test areas: empty data (renders `:empty` slot / nothing),
  single-point data (sparkline returns nil under 2 points; area_chart
  with one point), negative values (electricity prices go negative!),
  y_domain zero-span, bar_chart with zero max.
- `StatusDot` `size-1.5/2/2.5` classes assume Tailwind v4 size-*
  utilities — confirm against the kit's Tailwind setup.
- `ConnectAccountButton` uses an inline `onclick` — if the kit prefers
  a JS hook / `phx-click` + JS.dispatch pattern for CSP friendliness,
  that's a fair refactor; the contract (named popup + opener reload)
  should survive it.
- daisyUI 5 / Tailwind 4 assumed throughout, matching the kit.

## Follow-up candidates (not implemented)

- The dashboards module's widgets consuming `Chart` (natural second
  consumer; would validate the API quickly).
- A `datetime_area_chart` wrapper with axis tick labels, if demand
  appears.
- NordSwitch will adopt these once released (drop-in replacements for
  its hand-rolled versions) — ping Max/NordSwitch when a version ships.
