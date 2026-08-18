# PR #725 — Fix domain mode dropping the URLs of languages without a domain

Merge commit: `36f50745` (diff `e19d7aa3`) · Author: timujinne · Reviewed by: Claude

Files in scope: `lib/modules/sitemap/domain_mode.ex`, `test/integration/sitemap/domain_mode_test.exs`.

## Summary

In domain mode, a language with no domain of its own used to disappear from the
sitemap entirely instead of falling back into the primary domain's file. This PR
adds `domainless_entries/4`, called once per rebuild (guarded by `if primary?`) to
append synthetic entries — one per domainless language, per URL group — into the
primary domain's file, reusing the same `home_url/5` and `group_alternates/4`
helpers the mapped-language path already uses.

## Review

Traced the fix end-to-end: `home_url/5` hits its `nil ->` branch for a domainless
language (no entry in `host_by_lang`) and returns the un-stripped relative path with
locale prefix intact, exactly the behavior the PR describes. `domainless_entries/4`
only ever appends to the primary's own file and only for languages absent from
`host_by_lang`, so a fully domain-mapped setup produces `entries == own` — byte-for-byte
the pre-fix output, confirmed by the added "every language mapped ⇒ no domainless
entries" test. Alternates reuse the same `group_alternates/4` as the mapped path, so
hreflang sets stay consistent between a domainless entry and its mapped siblings.

Tests cover a translated group and a German-only group, assert an unrelated
domain-mapped language's file is untouched, and assert alternates parity — not a
narrow slice.

Doesn't interact with the two known pre-existing sitemap issues (3× group-walk in
`Sources.Publishing.collect/1`, flat-mode force-collect bypassing `enabled?/0`) —
this module doesn't touch either code path.

## Findings

**NITPICK** — `domain_mode.ex:128`: the inner `entries = if primary?, do: ..., else: own`
shadows the function's own `entries` parameter (`rebuild_for_domains(entries, base_url)`).
Legal, no compiler warning, but a reader skimming for "the input entries" can grab the
wrong binding. Not fixed — purely a naming readability nit, not worth a standalone
commit; leaving a note here so the next person touching this function sees it before
introducing a rename mid-diff of an unrelated change.

## Verdict

No bugs found. Correct, well-tested. No fix applied.
