# PR #669 — Chart, StatusDot and ConnectAccountButton core components

**Author:** mdon (Dmitri Don)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-28
**Verdict:** ✅ APPROVE — already merged. One NITPICK fixed post-merge, two
ecosystem-facing notes recorded. The component logic itself survived a
deliberately adversarial re-read; nothing was found to fix in it.

---

## Summary

Three new zero-JS core components (`Chart` with `line_chart` / `sparkline` /
`bar_chart`, `StatusDot`, `ConnectAccountButton`), an optional `value_color` and
a now-honored `rounded` on `stat_card`, a generic `PopupLink` hook in the
shipped JS bundle, and a `mix test.js` step wired into `precommit`.

The PR arrives with four prior review rounds already applied and 850 lines of
chart tests. That changes what a fifth pass is worth: re-litigating the geometry
would mostly re-derive what rounds 2–4 already settled. So this review went
looking for what a round that fixes *symptoms* tends to leave behind — a case
the whitelist misses, a clamp that holds on one sign but not the other, a
degenerate input the tests don't reach — and re-derived the arithmetic
independently rather than reading the fix notes.

It holds up. The round-4 resolution (collapsed domain scales to the **centre**;
a path that genuinely paints nothing renders a dot at the point's true position)
is the right shape of fix — it removes the class of bug rather than the
instance, and `axis_scale/3`'s degenerate clause is now the single place the
"no left or right" case is decided for both axes.

---

## NITPICK — `mix test.js` with an empty glob hands node the whole repo

**`mix.exs`**

```elixir
System.cmd("node", ["--test" | Path.wildcard("test/js/*.test.cjs")], …)
```

`node --test` with **no file arguments** walks the current working directory
looking for anything test-shaped. If the glob ever comes back empty — a renamed
directory, a `.mjs`/`.test.js` extension, running from the wrong cwd — the step
does not skip, it recursively scans `deps/` and `_build/` and reports whatever
it finds there. The failure mode is a `precommit` that hangs or fails on someone
else's code.

The guard the author wrote for the *other* optional dependency (node missing →
skip with a message) is exactly right; this is the same guard applied to the
other half of the precondition.

**Fixed** — the empty glob now skips with a message, symmetric with the
node-missing branch:

```elixir
cond do
  files == [] -> Mix.shell().info("[skip] no test/js/*.test.cjs files")
  System.find_executable("node") == nil -> Mix.shell().info("[skip] node not found — …")
  true -> …
end
```

Note that this step **never ran** on the merged tree: `precommit` executes its
aliases in order, and `quality.ci` was failing on a dialyzer error introduced by
PR #668 (see that review), so `test.js` was unreachable. Run directly it passes
— 21 tests, 0 failures.

---

## Ecosystem notes (not defects — record for the CHANGELOG)

**`stat_card`'s `rounded` attr becomes load-bearing.** It was previously
declared and ignored (the class was hardcoded `rounded-box`). Two consequences
for consumers outside this repo:

- a module that already passed `rounded="xl"` was getting `rounded-box`; it now
  gets `rounded-xl`, which is a **visible change** even though nothing in its
  code changed;
- `values:` is now a closed list, so a value outside it emits a Phoenix
  compile-time warning — which is a hard failure for any host compiling with
  `--warnings-as-errors`.

Both are the correct end state (the whitelist exists because Tailwind scans
source for literal class names, so an interpolated `rounded-#{@rounded}` would
produce a class with no CSS behind it). They just need saying out loud. No
in-repo call site passes `rounded`, so core itself is unaffected.

**`phx-hook="PopupLink"` needs a refreshed bundle.** The hook ships in
`priv/static/assets/phoenix_kit.js`, which hosts hold a *copy* of under
`priv/static/assets/vendor/`. A host that has not run `mix phoenix_kit.update`
since this release will log a LiveView "unable to find hook" error on the first
`connect_account_button`. It degrades correctly — the element is a real
`<a href>`, so the click just navigates full-page and the OAuth flow still
completes — but the console error will be reported as a bug.

---

## Checked and found correct

Recording the re-derivations so a later reviewer does not repeat them:

- **`bar_geometry/1` clamping holds on both signs.** Walked the four cases that
  broke in earlier rounds — all-zero (hairline at `height-1..height`, inside the
  box), all-negative (`baseline` at the top, bars hang down), one small negative
  among large positives (`baseline` on the bottom edge, the hairline is pulled
  up by `min(height - h)` instead of hanging off the canvas), and one negligible
  positive among large ones. Every rect lands inside the viewBox.
- **`h ≤ height - 4` always**, because `h` is `|scale(0) - scale(v)|` and
  `scale`'s range is `plot_h`. So `min(height - h)` can never produce a negative
  `y`, and the `max(0.0)` before it is belt-and-braces rather than load-bearing.
- **`plot_points/5` step mode.** `Enum.chunk_every(2, 1)` yields a trailing
  1-element chunk for every list including a singleton, so the `[{x, y}]` clause
  is always reached; `max(px.(x), px.(x_max))` is what stops the tail segment
  running backwards when the last datum overshoots an explicit `x_domain`.
- **`collapsed_point/1` uses `Enum.uniq`, not a length check** — two points
  sharing an x still draw a real vertical segment, and collapsing that to a dot
  would throw one of the two values away. Correct as written.
- **`sparkline_points/1` indexes before filtering.** `last = max(n - 1, 1)` uses
  the *raw* length, so dropping a bad sample leaves a gap rather than re-spacing
  the axis and changing the line's shape.
- **`y_pad/2`'s two-term fallback.** The range term is used whenever
  `y_max + range_pad > y_max` actually holds in floating point; the magnitude
  term catches the flat series where an absolute `1.0e-9` is below one ULP past
  ~1.0e7 and would vanish into the float. Both branches are needed.
- **`label_text/1`'s broad rescue** is deliberate and correctly reasoned:
  `to_string/1` on a keyword list raises `ArgumentError`, not
  `Protocol.UndefinedError`, so naming one exception would have left the most
  plausible bad label still crashing the page.
- **`aria-hidden={is_nil(@aria_label) && "true"}`** renders correctly in both
  directions — `false` makes HEEx drop the attribute entirely, so a labelled
  chart is not hidden.
- **`PopupLink`'s blocked-popup detection** treats `!popup`, `popup.closed` and
  `typeof popup.closed === "undefined"` as blocked, and only calls
  `preventDefault()` after that check — so the regression it replaces (an
  unconditional `return false` that killed the fallback navigation) cannot
  recur. `sameOrigin/2` rejecting a non-string `href` before `new URL` matters:
  a stringified `undefined` resolves as a *relative* path and would have passed.
- **`value_style/1`'s `;` strip is sufficient.** The output is a single CSS
  declaration inside a HEEx-escaped attribute, so breaking out needs either a
  `;` (stripped) or a `"` (escaped). Colour functions contain neither.

---

## Verification

- `mix format` — clean.
- `mix precommit` — clean, exit 0, verified unpiped (after PR #668's dialyzer
  fix; see that review).
- `mix test.js` — 21 tests, 0 failures.
- `mix test` for the four new component suites plus the SMTP suite — 122 tests,
  0 failures. Integration tests are auto-excluded here (no PostgreSQL), per the
  repo's standalone-testing stance.

---

## Post-release verification (1.7.217, 2026-07-28)

Independent re-check of the released tree (`d7008e00`):

- NITPICK: `run_js_tests/1` skips on an empty glob before the node check
  (`mix.exs:331`), so `node --test` can no longer be handed the whole repo.
- `mix test.js` re-run on the release commit — 21 tests, 0 failures.
- `mix quality.ci` (credo + dialyzer, the gate that had been masking this
  step via #668's dialyzer failure) — clean, exit 0.

Both ecosystem notes remain accurate for 1.7.217: `stat_card`'s `rounded` is
load-bearing with a closed `values:` list, and hosts need
`mix phoenix_kit.update` for the `PopupLink` hook to reach their vendored
`phoenix_kit.js` copy.
