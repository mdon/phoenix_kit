# Follow-up: PR #573 — Catalogue PDF Oban queue

Triaged 2026-06-03 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Punted (separate refactor)

- **`IMPROVEMENT - MEDIUM`: five near-duplicate `ensure_*_queue/2` functions**
  (`lib/phoenix_kit/install/oban_config.ex` — `ensure_posts_queue` :196,
  `ensure_sitemap_queue` :242, `ensure_shop_imports_queue` :287,
  `ensure_newsletters_delivery_queue` :332, `ensure_catalogue_pdf_queue` :380).
  They differ only in queue name + concurrency and could collapse into a single
  data-driven `ensure_queue(content, app_name, name, concurrency)`. Confirmed
  still live. The PR **explicitly deferred** this as out-of-scope (correct
  call — it spans installer codegen for every content module). Surfaced to Max
  2026-06-03; decision: **punt to a dedicated installer-dedup refactor**, not
  this sweep.

## Open

None (the punted refactor is tracked here as the trigger note).
