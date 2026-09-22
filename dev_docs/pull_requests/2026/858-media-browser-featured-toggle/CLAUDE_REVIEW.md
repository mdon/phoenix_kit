# PR #858 — MediaBrowser: featured star toggle on every image tile; AnnotationBurn: canvas sized by the ink it keeps

**Author:** timujinne · **Merged:** 2026-09-22 (4d6cd22b) · **Reviewer:** Claude · **Released in:** 2.37.3

## Summary

Two independent changes:

1. **MediaBrowser** — with `:featured` set, every image tile in the grid and
   stack views gets a star in the top-left corner. It is solid on the
   featured tile (`data-role="featured-badge"`, click → `unset_featured`)
   and outline on the rest (`data-role="featured-toggle"`, click →
   `set_featured`). The star moved out of the `click_file` target and now
   sits beside it, like the kebab, so a click never also opens the viewer.
   When the star is not interactive (readonly, select mode, trash), only the
   featured tile shows it, as a passive badge.
2. **AnnotationBurn** (`priv/static/assets/phoenix_kit.js`) — the burned
   canvas used to be sized by each `.etcher-shape`'s bounding box. A
   dimension's label group keeps a 0×0 leader at the overlay's origin, so
   the group's box stretched up to the viewer's corner. The new
   `burnInkBounds/4` measures only sized leaves and skips anything that is,
   or sits inside, `BURN_CHROME`.

Verdict: sound. The server-side `set_featured`/`unset_featured` clauses
already had readonly guards, and `notify_featured/2` is a no-op when the
host never opted in, so the new buttons add no new mutation path. On the JS
side, `burnIsChrome` (a `closest` walk) matches what the copy removes (a
`matches` on each element, which drops the whole subtree). I checked
Etcher's markup: `<defs>`/`<mask>`/`<pattern>` sit at the svg root, not
inside shapes, so skipping non-leaves loses no ink. The tests are thorough:
grid + stacks × select mode + trash, and the JS bounds cases including
straight lines.

## Findings

### BUG - MEDIUM — in select mode the passive star sat under the checkbox — FIXED

The select-mode checkbox is at `top-1 left-1 z-10`, `checkbox-sm` (20 px).
The passive badge is at `top-1.5 left-1.5`, `w-5 h-5` (20 px). The checkbox
covered all but a 2 px sliver of the star. The PR's own test ("select mode
turns the toggle into the featured tile's passive badge") checked that the
badge was in the DOM, but on screen it could not be seen. The old badge
(`top-2 left-2`) overlapped the same way, but the PR's point was to keep the
star in select mode.

Fix: `featured_badge` takes a `select_mode` attr, and in select mode the
passive badge uses `left-7` (right of the checkbox). The grid and stack
call sites pass it. Tests: the select-mode case now asserts `.left-7`, and
the trash case asserts `.left-1.5`.

### NITPICK — `set_featured` / `unset_featured` do not gate on trash or select mode server-side — not changed

The UI hides the toggle in both, but a stale client could still send
`set_featured` for a trashed file. Only `readonly` is enforced. The host
owns persistence and can reject a trashed uuid. Checking whether the file is
trashed would mean a lookup per click, and the featured choice is not a
destructive mutation. Left as is.

### NITPICK — the toggle changes both its `aria-label` and `aria-pressed` — not changed

A screen reader announces "Unset featured, toggle button, pressed". The
ARIA pattern keeps the label constant and lets `aria-pressed` carry the
state. This is harmless, and the tests pin it deliberately. Left as is.

### NITPICK — outline stars are always visible, not revealed on hover — not changed

The kebab on the same tile is `opacity-0 group-hover:opacity-100`, but the
outline stars always show, so a large grid shows a star on every image.
This looks deliberate: touch devices have no hover, and the star is the
feature's main affordance. Left to the author's design.
