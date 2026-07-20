# PR #655 — Update etcher to 0.8.2 — fix invisible circles on rotated canvas

**Author:** alexdont
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-20
**Verdict:** ✅ APPROVE — already merged; trivial, nothing to review.

---

## Summary

`mix.lock`-only bump of the `etcher` dependency, `0.8.1 → 0.8.2`, fixing invisible
circle annotations on a rotated `<Fresco.canvas>`. No source changes in this repo.

## Verification performed

- `mix.exs` pins `{:etcher, "~> 0.7"}` — `0.8.2` satisfies that constraint (same as
  `0.8.1` did), so no `mix.exs` change was needed.
- Confirmed no in-repo code depends on etcher internals that changed between patch
  versions (this repo only consumes `Etcher.layer`/`Etcher.Storage`, both unaffected
  by a rendering-only patch release).

Nothing to fix.
