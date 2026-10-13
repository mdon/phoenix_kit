# PhoenixKit release candidate — Codex review, 2026-10-13

Scope: `v2.61.0..32a02d503` plus review fixes. The version at review time is
still **2.61.0**; this is the unreleased candidate, not a published new version.

## Result

Claude's three fixes are sound. The independent review found and fixed additional
locale redirect/admin-path bugs, modal guard bugs, unsafe Telegram peek defaults,
and the missing route behind PR #929's integration tests. Individual reviews:

- [#924 — modal guards](../pull_requests/2026/924-modal-drag-textarea-unsaved-guard/CODEX_REVIEW.md)
- [#925 — boot discovery](../pull_requests/2026/925-boot-module-scan-once/CODEX_REVIEW.md)
- [#926 — Telegram](../pull_requests/2026/926-telegram-chat-ambiguity/CODEX_REVIEW.md)
- [#927 — language/URL policy](../pull_requests/2026/927-url-language-policy/CODEX_REVIEW.md)
- [#928 — admin Edit link](../pull_requests/2026/928-admin-edit-passthrough/CODEX_REVIEW.md)
- [#929 — admin layout hook](../pull_requests/2026/929-admin-layout-on-mount/CODEX_REVIEW.md)

## Changes outside the six PRs

Reviewed the animated GIF/WebP pipeline, cropped HDR gain maps, still-frame and
GIF-canvas fixes, rendition options, processing metadata, media-grid changes,
deep-zoom settings lock, and versioned/private View URLs.

Animation preservation is bounded by frames and total canvas pixels and restricted
to proportional primary renditions; crops/alternatives/opt-outs remain stills.
Frames are coalesced before resizing. HDR crops transform display coordinates
back into stored coordinates and apply the same window to the gain map. The
existing tests exercise all eight EXIF orientations, focal edges, animation
duration/canvas behavior, and real bucket-backed generation. Derived metadata
and variants remain guarded against a concurrent original replacement.

The storage settings/View changes retain permission and signed-URL gates.
No new schema migration was added after V217: `keep_animation` extends the
existing embedded JSONB rendition options. Removed an unused test variable
reported by the test-compilation gate.

Additional **BUG - MEDIUM** findings, fixed:

- **Turned HDR crops recorded reversed rendition dimensions.** A 300×100 crop
  of an orientation-6 photo correctly displayed as 300×100 but its instance
  recorded 100×300. Variant stats now read the canvas once and account for
  quarter-turn EXIF orientation. The actual bucket-backed crop reproduces the
  old failure and asserts the corrected instance dimensions.
- **Proportional HDR resizes fixed the stored width instead of displayed width.**
  A quarter-turned photo requested at 800 displayed pixels was 600 pixels wide.
  Resize now constrains the appropriate stored axis, scales the gain map along
  that same axis, and returns displayed dimensions for both resize and crop.
  Tests cover orientations 5–8 and a thin photo shrinking to one pixel.

The initial full run also exposed a sandbox queue failure in an HDR rendition
test: concurrent workers share one sandbox connection and were dropped after
138 ms. Test configuration now gives that queue a 1-second target rather than
50 ms. This changes no production setting; increasing the pool alone cannot
give one sandbox another connection.

## Validation

- Initial full database-backed run: 89 doctests, 9,282 tests, five failures,
  ten skipped, one excluded. Four failures were the missing #929 probe route;
  the fifth was the HDR worker sandbox queue failure. Both causes were fixed.
- Focused final locale/Telegram checks: 68 tests, zero failures.
- Actual admin-layout, account-gate, personal Telegram and locale integration
  checks: 40 tests, zero failures.
- HDR/animation unit and real-bucket integration checks: 74 tests, zero failures.
- Full rerun after the locale/modal/Telegram, route and sandbox fixes:
  **89 doctests, 9,287 tests, zero failures**, ten skipped, one excluded.
  After the subsequent HDR dimension fixes, **105 tests passed** across HDR,
  animation, variant-set generation, transparency/upscaling, and temporary-file
  cleanup suites, including real-bucket integration tests.
- `mix precommit`: passed after the additional HDR edits, including all
  **370 JavaScript tests** (compilation, test compilation, formatting, strict
  Credo, and Dialyzer under the project's configured suppressions).
- Production `compile --warnings-as-errors`: passed.
- `mix deps.audit`: no vulnerabilities. `mix hex.audit`: no retired/advisory packages.
- `mix docs` and `mix hex.build`: succeeded; `mix package.clean` removed the
  generated tarball. ExDoc reports existing references to hidden/private APIs;
  documentation generation does not treat them as errors.

Integration tests were enabled against PostgreSQL. The test role lacks
CREATEROLE, so its one specially tagged test is excluded; no database-less
integration exclusion was used.

## Release preparation

This review does not bump the version, change the release changelog, push, tag,
or publish. A subsequent release needs an entry covering **all** changes since
2.61.0, including the storage work and these fixes, followed by `mix prerelease`
on its committed release metadata.
