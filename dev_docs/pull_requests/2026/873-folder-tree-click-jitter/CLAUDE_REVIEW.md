# PR #873 — Fix the folder tree jitter on every click

**Author:** alexdont (Sasha Don) · **Reviewer:** Claude · **Date:** 2026-09-24
**Verdict:** correct; merged into `main`. Templates only. One doc fix in `AGENTS.md`.

## What it does

- **Jitter.** The row's folder icon and chevron swapped in the flow for a daisyUI
  `loading-xs` spinner, which is 14px against the icon's 16px, so the row slid
  2px on every click. The icon and spinner now sit stacked in one fixed 16px box
  (`relative` wrapper, `absolute inset-0` children), so neither can move the row.
- **Blink.** The spinner cross-fades in with `delay-300` while `.phx-click-loading`
  is on. When the class comes off, the delay doesn't apply, so a reply under 300ms
  never starts the fade and nothing shows.
- **Gutters.** `[scrollbar-gutter:stable]` on two inner scrollers whose height
  crosses the scroll threshold on navigation: the folder tree `<ul>` and the
  MediaBrowser content column.

## Verification

- The selectors are unchanged from before: `>` on the chevron (the button carries
  `phx-click`) and a descendant selector on the folder icon. Only `hidden` ↔ `inline-block`
  became `opacity` plus a transition.
- Tailwind v4 utilities beat daisyUI components, so `w-4 h-4` does override
  `.loading`'s own size.
- The rename-mode row (`folder_explorer.ex`, `hero-folder` next to the input) has no
  loading state, so it is correctly left alone.

## Findings

### IMPROVEMENT - MEDIUM — the AGENTS.md gutter rule reads as forbidding this PR (fixed)

AGENTS.md said "Do NOT re-add `scrollbar-gutter` overrides in layouts, PkDialog, or
modules". The PR's two additions are inner scrollers, the same case as the
`.drawer-side` exception already in `layout_wrapper.ex`, not the root/modal
compensation the rule was written against (2026-07-12 investigation). As worded,
though, the next agent to read the rule could delete all three. **Fix:** the rule now
says it covers the root/page gutter, and names the inner-scroller exceptions to leave
in place.

### NITPICK — every tree row now keeps an animated spinner in the DOM (not fixed)

Before, the spinner was `display: none` until loading. Now it sits at `opacity: 0`
permanently: one per row, two on expandable rows. daisyUI's `loading-spinner` is a
`mask-image` SVG with a SMIL `<animateTransform>`, so the invisible masks may keep
ticking. Browsers skip painting fully transparent content, and the tree is at most a
few hundred rows, so this isn't worth giving up the delayed cross-fade (which needs the
element rendered). Revisit only if a large tree profiles badly.
