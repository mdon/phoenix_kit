# FOLLOW_UP — PR #570 (V122/V123: spaces, staff translations, catalogue folders)

Triaged 2026-06-14 during the core quality sweep (Phase 1, last-5-Max-PRs scope).
Reviewer: `CLAUDE_REVIEW.md`. Every finding was verified resolved against the
current code — no still-live items.

## Fixed (pre-existing)

All findings target `priv/static/assets/phoenix_kit.js` (InfiniteScroll hook)
and `lib/phoenix_kit_web/components/core/pagination.ex` (`load_more/1`), both
still in core. Re-verified line-by-line:

- ~~`updated()` fires on every diff, no in-flight guard~~ — `updated()` only
  re-fires when `dataset.cursor` changed; `maybeLoad()` has an
  `if (this.loading) return` guard.
- ~~Guard could wedge on a no-op load~~ — 2s watchdog `setTimeout`, cleared in
  `clearGuard()` / `destroyed()`.
- ~~`data-cursor` written but never read in JS~~ — hook now reads
  `this.el.dataset.cursor` as the page signal.
- ~~`infinite` without `id` fails only at runtime~~ — `pagination.ex` raises
  `ArgumentError` at render time.
- ~~`resolve_cursor/1` nil crash + wasted compute~~ — computed only when
  `@infinite`; `is_binary`/`is_integer` guards + `""` fallback; plain `assign`.
- ~~V122 moduledoc said "Two" but listed three~~ — now reads "Three unrelated
  additions bundled together".

The "verified correct" items (V123 sku index, idempotency, PDF.js mount) needed
no action and remain unchanged.

## Open

None.
