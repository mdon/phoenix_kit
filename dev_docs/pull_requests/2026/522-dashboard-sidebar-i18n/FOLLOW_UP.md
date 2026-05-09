# PR #522 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**NITPICK: Public `guides/per-module-i18n.md` doesn't note the
  hot-reload safety.** Added a new "Common pitfalls" entry
  (`guides/per-module-i18n.md:514`) explaining that custom Tab
  iteration code should call `Tab.localized_label/1` rather than
  pattern-matching `gettext_backend` / `gettext_domain` directly —
  the library's `Map.get/2`-based resolvers gracefully handle
  old-shape structs cached across the upgrade window, but
  pattern-matching consumers wouldn't. Surfaces the contract that
  was previously only documented in the `Tab` moduledoc.~~

## Skipped (deferred / out-of-scope)

- **IMPROVEMENT - LOW: `gettext_domain` field could collapse to a
  tagged union.** Design call — current shape (`gettext_backend` +
  `gettext_domain`) ships a string field for every Tab even when no
  translation is configured. Compression to `gettext: backend |
  {backend, domain}` is a real possibility but a breaking API
  change. Worth considering before too many modules adopt the API
  and migration cost grows.
- **IMPROVEMENT - LOW: `localized_label/1` builds a domain string
  per call.** Defensive choice — matches the hot-reload safety
  rationale. Optimizing it would re-introduce the `KeyError` risk on
  stale-shape structs. Skip.
- **IMPROVEMENT - LOW: `gettext_backend` stored as module atom is
  brittle on rename / removal.** Edge case — `Code.ensure_loaded?(backend)`
  guard would close it. Not load-bearing today; revisit if a
  removed-plugin incident materialises.
- **NITPICK: Test couples to `PhoenixKitWeb.Gettext`'s actual `ru`
  catalogue.** Defining a test-only Gettext backend with its own
  minimal `.po` catalogue would isolate the test. Worth doing before
  the test count grows; out of scope here.
- **NITPICK: `dev_docs/instructions/...md` 442-line procedure doc
  bundling.** Meta concern — the doc is high-quality but inflates
  the PR diff. Already shipped; can't unbundle retroactively.
- **NITPICK: PhoenixKit's own admin tabs not migrated.**
  Acknowledged as explicit follow-up in PR #522's "Non-goals". Will
  ship in a future PR migrating the ~19 core tab registrations.

## Open

None.
