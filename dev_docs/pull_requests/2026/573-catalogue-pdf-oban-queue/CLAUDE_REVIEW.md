# PR #573 — Add catalogue_pdf Oban queue to the installer

**Reviewer:** Claude (Opus 4.8)
**State:** MERGED into `dev` (2026-05-30). Review is post-merge; findings are follow-up candidates.
**Scope:** 1 file — `lib/phoenix_kit/install/oban_config.ex`. Adds `catalogue_pdf: 2` to the fresh-install default queues block + a new `ensure_catalogue_pdf_queue/2` for existing host configs, wired into `update_existing_oban_config/3`, plus the matching `@dialyzer` nowarn entry.

## Verdict

Correct and consistent. The change closes a real silent-failure gap: `phoenix_kit_catalogue` enqueues `:catalogue_pdf` jobs and Oban only runs listed queues, so without this entry the jobs sit `available` forever and text extraction never completes while uploads appear to succeed. Adding the queue unconditionally (idle queue ≈ free) is the right call and matches the sibling `posts`/`sitemap`/`shop_imports`/`newsletters_delivery` ensure functions.

`ensure_catalogue_pdf_queue/2` is a faithful structural copy of `ensure_newsletters_delivery_queue/2`: same idempotency guard (`~r/catalogue_pdf:\s*\d+/`), same queues-block regex, same trailing-comma handling, same graceful `nil` → "please add manually" fallback. The dialyzer nowarn arity (`: 2`) matches the function. Pipe ordering in `update_existing_oban_config/3` is sound — when run after `ensure_newsletters_delivery_queue` adds a comma-less last entry, the catalogue step's `has_trailing_comma` check prepends the comma correctly.

No CRITICAL/HIGH/MEDIUM findings.

---

## Verified correct

- **Fresh-install default block.** `newsletters_delivery: 10` gains a trailing comma and `catalogue_pdf: 2` is appended as the new comma-less last entry — valid keyword-list syntax.
- **Idempotency.** Re-running `mix phoenix_kit.update` on a config that already lists `catalogue_pdf` short-circuits at the guard. A host that hand-added it is not double-written.
- **Graceful degradation.** Unparseable host queues block → `Mix.shell().error` with a manual-add hint, returns `content` unchanged. No crash.
- **Concurrency 2** is a reasonable default for `pdfinfo`/`pdftotext` shell-outs (CPU/IO-bound, not something you want 10-wide).

---

## IMPROVEMENT - MEDIUM — five near-identical `ensure_*_queue/2` functions (this PR adds the 5th)

`ensure_sitemap_queue`, `ensure_shop_imports_queue`, `ensure_newsletters_delivery_queue`, and now `ensure_catalogue_pdf_queue` are ~30-line copies differing only in queue name, concurrency, and the manual-add hint string. The duplicated regex/trailing-comma/`String.replace` body is the kind of thing that drifts (a fix to one won't reach the others). A single `ensure_queue(content, app_name, name, concurrency)` driving all of them off a `[{:sitemap, 5}, {:catalogue_pdf, 2}, ...]` list would collapse the repetition and make the next queue a one-line data change.

Not a bug, and the PR deliberately follows the established pattern rather than refactoring mid-feature — which is the right scope discipline for a merge. Flagging as a future cleanup candidate for the whole family, not a defect in this PR.

## NITPICK — no unit test for the string transform

The ensure-queue family has no test coverage (pre-existing), and per project norms (`mix precommit` is the bar, PhoenixKit isn't standalone-test-driven for installer codegen) this matches precedent. If the MEDIUM refactor above is ever done, the consolidated `ensure_queue/4` would be a clean, cheap unit-test target (pure `String.t() -> String.t()`), worth adding at that point.
