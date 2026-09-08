# Claude Review — PR #791

**Title:** Correct the external-module JS hook guidance and the routing-pattern lists in AGENTS.md
**Author:** mdon
**Merge commit:** 70cccc41
**Verdict:** Approve — no issues

## Summary

Docs-only. Fixes three stale spots in `AGENTS.md`: drops a reference to the
already-retired `dev` branch, corrects the JS-hooks section (external modules
now ship hooks as a prebuilt bundle via `js_sources/0`, not an inline
`<script>` — the old text was superseded by the `:phoenix_kit_js_sources`
compiler), and expands/corrects the route-discovery module lists (tab-only
vs route-module-only vs mixed).

## Findings

None. Checked the current module lists and the `js_sources/0` /
`:phoenix_kit_js_sources` compiler description against the code — the
corrected text matches reality.
