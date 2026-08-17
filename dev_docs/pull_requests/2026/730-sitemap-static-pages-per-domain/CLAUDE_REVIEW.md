# PR #730 — Give every mapped domain its own static pages in the sitemap

**Author:** timujinne · **Merged:** 280433f7 (merge of 1bc825dd, 1513e80b, d1b4e044)
**Reviewer:** Claude (third independent pass, after two rounds already folded
into this PR by Claude Opus 5)

## Summary of the change

Under `DomainMode`, a language with its own mapped domain (e.g. `.fr`) was
missing its home page (and other static routes) from that domain's sitemap,
because `Sources.Static.collect/1` only ever emitted for the default
language — correct for prefix installs, wrong once a language is served
prefix-free from its own host. Fixed by widening `Static.collect/1` under an
explicit `domain_pass: true` opt, with the prefixed intermediate collected
separately by the generator (`domain_static_entries/2`) and appended only to
the domain-mode pass — never to the legacy/index set served to unmapped
hosts. Two extra fixes rode along: `sitemap_non_page_pipelines` (a
replace-not-extend escape hatch so a host can un-blacklist a `:api` pipeline
that serves real pages) and `Sitemap.regenerate/1` now refusing an
unconfigured `site_url` instead of silently writing host-less `<loc>`s.

## Findings

No new findings. This PR already went through two rounds of adversarial
self-review before merge (commits `1513e80b`, `d1b4e044`), each of which
fixed a real defect:

1. Round 1 landed the core `Static.collect/1` widening but left no escape
   hatch for `:api`-pipeline hosts and let `Sitemap.regenerate/1` accept an
   unconfigured base URL.
2. Round 2 caught that the locale-prefixed intermediate (`/fr/`) was leaking
   into the legacy/index set via the shared `entries` collection — fixed by
   gating the widening behind `domain_pass: true` and having the generator
   collect the domain-only copies itself (`domain_static_entries/2`),
   appended after the legacy set is already written in both flat mode
   (`do_generate_flat` saves before calling `generate_domain_sitemaps`) and
   index mode (independent collection inside `generate_domain_sitemaps`).

Traced through this pass, specifically checking for regressions the two
prior rounds might have missed:

- **Canonical-path grouping is consistent.** `get_languages()` and
  `DomainMode.domains()` both normalize language codes through
  `DialectMapper.extract_base/1` before `domain_static_entries/2` intersects
  them, so a dialect code (`en-US`) doesn't cause an under-selection bug
  against the base-code `mapped` set.
- **The custom-URL prefix-strip claim is pinned by a test**, not just
  argued: `static_domain_pages_test.exs` asserts a custom URL reaches the
  mapped domain at its plain path, never `/fr/...`.
- **`regenerate/1`'s new empty-base-url guard matches the scheduler's
  pre-existing one** (`SchedulerWorker.valid_base_url?/0`), so the two entry
  points agree.
- **`sitemap_non_page_pipelines`'s `String.to_atom` on a JSON-decoded
  setting** mirrors the existing `sitemap_protected_pipelines` pattern
  verbatim (admin-only setting, not attacker input) — not a new exposure.

## Validation

- `mix test test/integration/sitemap/` — 69 tests, 0 failures.
- `mix precommit` — clean (compile w/ warnings-as-errors, credo --strict: no
  issues, dialyzer: 233/233 pre-existing ignored, JS tests: 45/45 passed).
