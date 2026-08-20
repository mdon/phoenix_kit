# Claude Review — PR #738 "Fix duplicate `<loc>` and a crash-to-empty-sitemap defect left after #730"

**Merge commit:** cf17c6b83fb222a51d0bba435faca6eeeb54c391
**Author:** timujinne (pr/sitemap-static-pages-per-domain)
**Files (per branch history):** `lib/modules/sitemap/domain_mode.ex`, `lib/modules/sitemap/sources/router_discovery.ex`, plus tests

## Summary of the change

This PR's two commits (`ed1c5ab4` "Fix two defects found reviewing the
follow-ups", `ebf53a2d` "Cover index mode in the legacy-set leak test") carry
the **exact same patch content** as commits `27a132bd`/`b1e2cba5`, which
already landed on `main` and were reviewed under
[`../731-sitemap-duplicate-loc-and-junk-pipeline/CLAUDE_REVIEW.md`](../731-sitemap-duplicate-loc-and-junk-pipeline/CLAUDE_REVIEW.md).
Confirmed: `git diff f283691b cf17c6b8` (the merge's own parent vs. the merge
commit) is empty — the merge introduced zero net tree changes because `main`
already had this content. This is a benign re-merge (e.g. a stale/duplicate
branch reaching GitHub after the equivalent commits were already
cherry-picked/re-applied to `main`), not a code change to review fresh.

## Review

Re-verified the fix is actually present and correct in the current tree:

- `lib/modules/sitemap/sources/router_discovery.ex`: `safe_to_atom/1` has a
  catch-all clause returning `nil` for non-atom/non-binary elements, with
  `to_atoms/1` filtering those out — confirmed present, matching PR #731's
  description of the fix for the settings-typo-emptying-the-whole-source bug.
- `lib/modules/sitemap/domain_mode.ex`: domainless-entry dedup against the
  primary domain's own locs — confirmed present per PR #731.

## Findings

None beyond what #731 already covered. No new code to fault.

## Verdict

Clean (duplicate merge of already-reviewed, already-verified content).
Release-safe as-is; nothing to fix.
