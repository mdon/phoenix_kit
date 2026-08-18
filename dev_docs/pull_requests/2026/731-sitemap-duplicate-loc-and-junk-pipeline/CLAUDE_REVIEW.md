# PR #731 — Fix duplicate `<loc>` on the primary domain, and a settings typo emptying router discovery

**Author:** timujinne (self, as Claude Opus 5) · **Merged:** 18caa35b (merge of
27a132bd, b1e2cba5) · **Base:** 2.12.0
**Reviewer:** Claude (independent pass, post-merge, for the 2.12.1 patch release)

## Summary of the change

Two defects in code that landed with #730 (2.12.0), found by re-reviewing that
PR's own follow-up commits after it was already merged:

1. **Duplicate `<loc>` on the primary domain.** `DomainMode.rebuild_for_domains/2`
   appended `domainless_entries/4` (URLs for languages with no domain of their
   own, re-hosted on the primary) straight onto the primary's `own` set. When
   the primary domain maps a language that is NOT the site default, and the
   site default itself has no domain, the default language's unprefixed home
   page collides with the primary's own-language home page — same `<loc>`
   twice in one file. Fixed by `extra_for_primary/5`: build a `MapSet` of
   `own`'s locs and reject any domainless entry that already resolves to one.
2. **One junk element in `sitemap_non_page_pipelines` / `sitemap_protected_pipelines`
   emptied the whole source.** `safe_to_atom/1` only had clauses for atoms and
   binaries; a JSON array containing a non-string/non-atom element (e.g. a
   stray integer from a hand-edited settings field) raised
   `FunctionClauseError`, caught by `collect/1`'s top-level rescue, which
   returned `[]` — silently dropping every discovered route. Fixed with a
   `to_atoms/1` wrapper that filters out anything `safe_to_atom/1` can't
   convert instead of letting it blow up the whole pipeline.

## Findings

No new findings. Traced both fixes independently against the surrounding code:

- **`extra_for_primary/5` dedups against the right set.** `own` is already a
  flat list across every canonical group for the primary's own language, and
  `domainless_entries/4` is likewise flat across all groups — so the
  `MapSet`-based reject correctly catches a global (file-wide) duplicate, not
  just a same-group one. Two distinct domainless languages can't collide with
  each other here: `home_url/5` only strips a language's own prefix when that
  language *has* a mapped host (`host_by_lang[lang]` present), so a
  domainless entry keeps its full `/lang/...` prefix and stays distinct from
  every other domainless language's entry — the only possible collision is
  the one the fix targets, an unprefixed default-language entry landing on
  the primary's bare root.
- **Alternates are untouched by the drop.** The rejected domainless entry
  would only have contributed a `<loc>`; `group_alternates/4` still computes
  every language's `hreflang` link (including the dropped one's) independent
  of whether that language's own file-entry survives the dedup, so hreflang
  correctness for the *other* domain's file isn't affected by this fix.
- **`to_atoms/1` is applied uniformly.** Both call sites
  (`non_page_pipelines/0` and `get_custom_protected_pipelines/0`) route
  through the same helper, so the hardening isn't asymmetric between the two
  settings that share the pattern.
- **`String.to_atom/1` on admin-only settings is pre-existing, not a new
  exposure** — same as noted in the #730 review; these settings aren't
  attacker-controlled input.

## Validation

- `mix test test/integration/sitemap/static_domain_pages_test.exs test/integration/sitemap/router_discovery_api_pipeline_test.exs` — 15 tests, 0 failures.
- `mix precommit` — clean (format, compile with warnings-as-errors, credo --strict, dialyzer, JS tests).
- `mix test` (full suite) — 43 doctests, 3819 tests, 0 failures, matching the count the PR description claimed on its branch.

## Outcome

Shipped as-is; no additional fixes needed. Released as 2.12.1 (patch — bug
fixes only, no new public API).
