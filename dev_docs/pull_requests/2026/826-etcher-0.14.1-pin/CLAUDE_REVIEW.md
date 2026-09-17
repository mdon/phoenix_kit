# PR #826 — Etcher pin to 0.14.1

**Author:** alexdont (`etcher-0.14.1-pin`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-17 (post-merge)

2 files: `mix.lock` moves `etcher` 0.14.0 → 0.14.1, and the jsDelivr tag in
`priv/static/assets/phoenix_kit.js` moves `v0.14.0` → `v0.14.1`.

## Verdict

Correct and complete. No findings.

- The two halves move together, which is the whole point of the pin discipline —
  `test/phoenix_kit_web/vendored_cdn_pins_test.exs` asserts the `gh/` tag names the
  version Hex resolved, and it passes.
- `mix.exs` keeps `{:etcher, "~> 0.14.0"}`. The requirement already admits the
  patch, so no bump is needed, and nothing in core calls a 0.14.1-only API — the
  release is behavioural (shaft labels take their line's colour, the dimension
  drops into a skippable label editor on release, the shaft breaks under the
  editor while typing, a label-prompted shape stays fresh). No floor to raise
  either; the floor comment block in `mix.exs` stays accurate.
- `fresco` stays inside etcher 0.14.1's own requirement
  (`~> 0.5.9 or … or ~> 0.12.0`) — core resolves 0.12.x.
- The lock change is the single `etcher` line; nothing else drifted.
