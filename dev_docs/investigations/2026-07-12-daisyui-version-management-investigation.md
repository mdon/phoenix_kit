# daisyUI version management — investigation, custody experiment, and the advisory outcome

**Date:** 2026-07-12
**Trigger:** user bug report on `phoenix_kit_dashboards`' create modal
**Outcome:** scrollbar-gutter compensations removed from core; a full
vendor-in-core custody implementation was built, verified, and **rejected**
(hosts own their assets); shipped instead as advisory minimum-version warnings
(`PhoenixKit.Install.DaisyUI` + install/update/doctor).

---

## 1. The bug report

> "On the new dashboard popup, when they clicked the cancel button a scroll
> bar showed up instead."

Reproduced in `phoenix_kit_parent` with classic (space-taking) scrollbars on
the dashboards list page (a normal flowing page tall enough to scroll the
document). Frame-by-frame capture of the create-modal cycle:

| moment            | scrollbar gutter | document scrollbar | layout |
|-------------------|------------------|--------------------|--------|
| baseline          | —                | visible (15px)     | content in `viewport − 15px` |
| modal open        | forced `auto`    | hidden by page lock| content expands 15px wider |
| after Cancel      | restored         | back               | content shrinks 15px, scrollbar pops in |

The scrollbar was never *added* by Cancel — it was legitimately there, got
hidden for the modal's lifetime, and its return was maximally visible because
the space it needs had been given away while it was gone.

## 2. Root cause — two fixes fighting each other

1. **daisyUI 5.0.x** (what every host vendored): on modal/drawer open it sets
   `overflow: hidden` on `:root` (the page lock) **plus** an unconditional
   `scrollbar-gutter: stable` — deliberately reserving the hidden scrollbar's
   15px so content doesn't reflow. Correct on scrolling pages; on
   *non-scrolling* pages the reservation is pure artifact — the modal backdrop
   sizes against the reduced viewport and a phantom grey/white strip shows at
   the window's right edge (painted base-100 by daisyUI, which mismatches any
   non-base-100 host background).
2. **Core's compensations**, accreted over time to kill that strip:
   - since 1.0.0: `class="[scrollbar-gutter:stable]"` on `<html>` in core's
     two standalone root layouts (latent in host-shell mode — the host's root
     layout renders instead);
   - 2026-05-23 (`43ab0990`, the modal→native-`<dialog>` sweep): PkDialog's
     refcounted inline `scrollbar-gutter: auto !important` on open;
   - 2026-07-08 (`9bfed196`, released 1.7.179): the unlayered
     `:root:has(.modal-open, …) { scrollbar-gutter: auto }` counter-rule in
     the admin LayoutWrapper + `layouts/root.html.heex`, covering all daisyUI
     modal patterns and the drawer. Its comment *documented the trade-off*:
     "on pages that DO scroll, classic-scrollbar users see a ~15px reflow when
     a modal opens … less jarring than the mispainted strip."
     (`phoenix_kit_dashboards` had carried its own per-page copy of the same
     rule and deleted it the same day in favor of core's.)

The user report was that documented trade-off being hit in the wild. Why it
survived browser verification: on default macOS, scrollbars are overlays that
occupy zero layout width — both the reservation and the override are visual
no-ops. You need a space-taking scrollbar AND a page that scrolls.

## 3. Ecosystem research

- **Who owns daisyUI:** the HOST app. `mix phx.new` (Phoenix 1.8, no npm)
  vendors `assets/vendor/daisyui.js` + `daisyui-theme.js` at project creation;
  the host's `app.css` loads them via `@plugin` with host-owned theme config
  blocks. phoenix_kit never installed, checked, or pinned it — its only
  mention was a themes-disabled regex in the update task. Contrast:
  `phoenix_kit.js` IS custodied (copied by install, refreshed by update,
  cache-busted).
- **Fleet survey:** every host in the workspace with a vendored copy was on
  **5.0.35** (phoenix_kit_parent, polymarket_bot, farm_keeper_new,
  printer_farm_receiver) — whatever phx.new scaffolded; nobody had ever
  upgraded one.
- **Upstream:** daisyUI was at 5.6.17 (now 5.6.18; very active cadence).
  The gutter defect was fixed across 5.1.0→5.6.x in `rootscrollgutter.css`,
  verified by inspecting the 5.6.17 bundle: a scroll-driven animation
  (`animation-timeline: scroll()`) sets `--page-has-scroll` only when the page
  really scrolls, and the rule computes
  `scrollbar-gutter: var(--page-has-scroll) var(--page-scroll-lock) stable`
  (the space-toggle trick) — gutter reserved **only** when a modal is open AND
  there was a real scrollbar to hide. Handles both page types and the drawer.
- **Key insight:** core wasn't "hoping daisyUI is up to date" — its
  compensations *assumed daisyUI is old*. A host that diligently upgraded to
  5.6 would have behaved WORSE (core's unconditional `auto` forcing defeats
  upstream's conditional reservation → the jump returns). Silent version
  coupling, calibrated to the stale version, invisible by construction.

## 4. Options analysis for version management

| option | verdict |
|---|---|
| **npm dependency** | Phoenix 1.8 deliberately dropped npm; reintroducing Node as a build requirement for one file is a regression. |
| **Version pin + download at install** (the `tailwind`/`esbuild` hex-package pattern) | That pattern exists because platform-specific multi-MB binaries *can't* ship in a hex package. daisyUI is a ~330KB platform-independent text file — exactly what hex packages are for. Downloading adds network-at-build-time (offline/CI breakage), supply-chain surface (GitHub release assets are **mutable** — a tag's file can be re-uploaded), and availability coupling. |
| **`@plugin` straight from the dep** (`deps/phoenix_kit/priv/vendor/...`) | Dies on plumbing: **path deps never materialize under `deps/`** (verified — the parent has no `deps/phoenix_kit`), `_build/<env>/...` paths are MIX_ENV-specific, and emitting the `@plugin` into the generated `_phoenix_kit_sources.css` fails because plugin *config* (themes) is attached to the invocation and must stay host-owned. |
| **Vendor in core + copy into host** ("custody") | Works for every dep type and env; the copy is the pointer, enforced identical on every compile. Built and verified — then **rejected** (below). |
| **Advisory warnings only** | What shipped. |

## 5. The custody experiment (built, verified, rejected)

Implementation (commits `8b77f6c9` + `a7578c9f`, pushed to the fork then
retired; the fork's main was later reset past them):

- daisyUI 5.6.17 (`daisyui.js` + `daisyui-theme.js`, MIT) vendored in core's
  `priv/vendor/`; `pinned_version/0` parsed out of the bundle itself.
- Synced over the host's `assets/vendor/` copies at four touchpoints:
  `phoenix_kit.install` (Igniter step), `phoenix_kit.update` (before its asset
  rebuild), the `:phoenix_kit_css_sources` compiler on **every host compile**
  (the no-drift enforcement backstop), and a `phoenix_kit.doctor` check.
  Only when the host file existed; `manage_daisyui: false` opt-out.
- All gutter compensations deleted (see §6).

Verified end-to-end in the parent (native classic scrollbars): zero reflow
through the whole open→cancel cycle on the scrolling page; no phantom strip on
the viewport-locked builder; doctor `PASS daisyUI 5.6.17 (pinned by
PhoenixKit)`; precommit green.

**Rejected by the maintainer:** hosts own their assets — core must not
overwrite files in the host's repo. The custody machinery (vendored files,
sync, compiler hook, config flag) was fully removed.

## 6. What shipped (commit `d571a55c`)

1. **Compensations removed** — both CSS counter-rules (LayoutWrapper +
   `root.html.heex`) and PkDialog's inline override + `_PkDialogOpenCount`
   refcount machinery (~90 lines of JS). With daisyUI ≥ 5.1 the conditional
   gutter makes them obsolete; on scrolling pages they *caused* the reported
   bug. **Do not re-add `scrollbar-gutter` overrides in core layouts,
   PkDialog, or modules.**
2. **Advisory warnings** — `PhoenixKit.Install.DaisyUI` declares
   `minimum_version/0` (**5.6.0**; verified against 5.6.17/5.6.18) and
   `check/0` → `:ok | {:outdated, v} | :unversioned | :missing`. Warned from:
   - `mix phoenix_kit.install` — Igniter warning with curl upgrade steps
   - `mix phoenix_kit.update` — shell warning next to its CSS/JS refresh steps
   - `mix phoenix_kit.doctor` — "daisyUI Version" check (four states)

   Advisory only; nothing ever touches host files. Unit tests:
   `test/phoenix_kit/install/daisyui_test.exs`.
3. **Host consequences** — a host on daisyUI < 5.1 gets daisyUI's *stock* old
   behavior (the gutter strip while a modal is open on non-scrolling pages;
   no jump on scrolling pages) plus the warning; the cure is updating the two
   vendored files, not core CSS. phoenix_kit_parent was hand-upgraded to
   5.6.18 (the exact procedure the warning prescribes); the other workspace
   hosts will warn until their files are curled forward.

## 7. Measurement gotchas (keep these — they cost real time)

- **`clientWidth` does not count a reserved gutter.** Under
  `overflow: hidden` + `scrollbar-gutter: stable`, Chromium reports
  `clientWidth == innerWidth` even though layout stays narrower. Measure
  `body.getBoundingClientRect().width` / a centered container's `x` for
  user-visible reflow — the gap metric produced a false "fix didn't work."
- **A `::-webkit-scrollbar { width: 15px }` sim** makes real scrollbars take
  space (good for demoing the *old* bug on overlay-scrollbar macOS) but does
  NOT make `scrollbar-gutter: stable` reserve anything — the reservation uses
  the platform scrollbar width (0 for overlay). You cannot verify the fix
  with the sim; you need real classic scrollbars.
- **macOS "Show scroll bars: Always"** gives real classic scrollbars — but a
  long-lived Playwright/Chromium instance may predate the observed setting;
  relaunch the browser before trusting its scrollbar mode. Probe with
  `div{overflow:scroll}` `offsetWidth - clientWidth`.
- **Playwright-bundled Chromium quirk (2026-07):** with *overlay* scrollbars,
  that build reserves ~15px under `scrollbar-gutter: stable` anyway (root
  element shrinks while a modal is open) — against the spec (overlay ⇒
  nothing to reserve). This is stock-daisyUI-≥5.1-behavior × browser quirk,
  identical on 5.6.17 and 5.6.18 (mechanisms byte-diffed), NOT caused by
  phoenix_kit. If a default-macOS user ever reports a small modal-open shift,
  this is the trail — upstream daisyUI/Chromium territory, not core CSS.
- **Playwright MCP full-page screenshots** timed out on these admin pages
  ("waiting for element to be stable") with zero animations present — tool
  quirk; fall back to programmatic computed-style checks.

## 8. Conclusion

The daisyUI version-control problem was researched in full and a complete
custody/pinning implementation was built and verified — **we decided not to
implement it** (maintainer call: hosts own their assets). What remains in
core is the minimal correct stance: rely on modern daisyUI's own conditional
gutter (compensations deleted, never to return) and tell hosts when their
vendored copy is too old to deliver it (`PhoenixKit.Install.DaisyUI`,
minimum 5.6.0, warnings in install/update/doctor). If Tailwind ever grows
package-resolved plugin references (or Phoenix reintroduces a JS package
manager), direct consumption of a core-shipped plugin becomes possible and
this file is the starting point.
