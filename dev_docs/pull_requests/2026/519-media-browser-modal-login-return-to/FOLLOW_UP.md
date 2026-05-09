# PR #519 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**IMPROVEMENT - LOW: `media_browser.html.heex:1230-1233` comment
  still references the removed `viewer` attr.** Updated to describe
  the new default behaviour — clicking a file in non-admin /
  non-select_mode opens the modal viewer; bulk-select reaches via the
  toolbar's Select button. The first comment line now reads "Default
  click target for non-admin, non-select_mode browsers" instead of
  "Activated by passing `viewer={true}`."~~

- ~~**IMPROVEMENT - LOW: `login_path_with_return_to/1` path equality
  is path-prefix-sensitive.** Trailing-slash variants now compare
  equal: both sides go through `String.trim_trailing(path, "/")`
  before the equality check. A user landing on `/users/log-in/`
  (with trailing slash) no longer round-trips back to itself via
  `?return_to=`. The comparison's `login_path_canonical` is computed
  once outside the case to avoid recomputing on every URI shape
  match.~~

## Skipped (deferred / out-of-scope)

- **IMPROVEMENT - MEDIUM: Default click behaviour flipped from select
  to modal-viewer; no deprecation cycle for picker callers.** Design
  decision — the new default is the right shape per the PR body's
  rationale ("read-only modal preview on click is the intuitive
  default; the previous 'click adds to hidden selection' was an
  admin-internal pattern that surprised picker users"). External
  callers depending on the old picker default need to adopt the
  toolbar Select button workflow. Worth a one-line "## Breaking
  changes" entry in the next CHANGELOG bump.
- **NITPICK: `get_connect_info(socket, :uri)` works in both
  disconnected and connected mounts.** Informational — the catch-all
  branch is future-proofing, not a behavior gap. No action needed.
- **NITPICK: Panzoom CDN dependency / SRI hash.** Adding SRI to
  CDN-loaded scripts is a workspace-wide pattern change (also affects
  SortableJS, Chart.js, Panzoom). Out of scope for #519's review
  surface — worth a separate "harden CDN dependencies" PR.
- **NITPICK: `!important` chain on modal-box.** Well-commented;
  daisyUI plugin-variant extraction is over-engineering for one site.
- **NITPICK: Chevron-button comment placement.** Cosmetic — comment
  duplication for the `has_next` block. Style preference.

## Open

None.
