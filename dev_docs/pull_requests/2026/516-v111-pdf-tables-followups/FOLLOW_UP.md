# PR #516 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**IMPROVEMENT - LOW: `interpolate_url/3` has a dead atom-key fallback.**
  `defaults[String.to_atom(key)]` removed
  (`lib/phoenix_kit/integrations/oauth.ex:233-241`). The chain now reads
  `integration_data[key] || defaults[key] || ""` — two well-defined
  string-keyed sources, no atom-table growth on a never-taken path.
  Comment expanded to make the contract explicit: provider authors must
  use string keys for `url_defaults`. Verified via OAuth test suite (21
  / 21 passing).~~

## Skipped (deferred / out-of-scope)

- **IMPROVEMENT - MEDIUM: `up/1` opens with unconditional `DROP TABLE …
  CASCADE`.** Modifying an applied migration in a release that's
  already shipped is risky; the destructive shape is documented but
  unchanged. Worth a clean-up migration if catalogue accumulates real
  data before the catalogue's 1.0 release. Out of scope for this
  triage.
- **NITPICK: `phoenix_kit_cat_pdf_pages.content_hash` `type:
  :"varchar(64)"`.** Same constraint as above — applied migration
  shape preserved. Out of scope.
- **NITPICK: `phoenix_kit_cat_pdfs.byte_size` is nullable.** Same
  constraint — applied migration. Out of scope.
- **NITPICK: `phoenix_kit_cat_pdf_page_contents` immutability not
  documented.** Worth a moduledoc note, but the moduledoc already
  describes the table's role as a content-addressed dedup cache,
  which implies immutability. Cosmetic deferral.
- **NITPICK: PR body verification gap (`mix precommit` not
  end-to-end).** PR-body concern; nothing to action in repo.
- **NITPICK: `IntegrationPicker` defensive `is_map(conn[:provider])`
  guard comment.** Cosmetic — current shape is correct, comment
  duplication is style preference. Out of scope.
- **NITPICK: FOLLOW_UP commit-pinning convention.** Aspirational —
  this and other follow-ups in `dev_docs/pull_requests/2026/` would
  benefit from explicit commit pinning, but retrofitting the existing
  ones isn't necessary to ship.

## Open

None.
