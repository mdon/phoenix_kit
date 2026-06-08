# PR #585 Follow-up — Host-wiring docs, AITranslate.Embed macro, media-detail Leaf fix, V131

After-action for the two reviews in this folder (`PINCER_REVIEW.md`, `MISTRAL_REVIEW.md`). Both verdicts were **Approve**; all findings were non-blocking follow-ups, and every one was resolved by the maintainer post-merge (the reviews' own "Fix Status" sections carry the inline record). Verified against current `phoenix_kit` `main`.

## Fixed (post-merge, maintainer commits)
- ~~**IMPROVEMENT-MEDIUM** — align `media_detail.ex` Leaf handler with the canonical `MediaBrowser.Embed` pattern (`apply/3`, `:pass`, `Logger.warning` on unexpected returns).~~ Fixed in `34cb7aac`, then **superseded by extraction**: the now-duplicated handler was pulled into `PhoenixKitWeb.CommentsForwarding.forward_leaf_changed/2` (`d9a483a2`); both `media_detail.ex` and the `MediaBrowser.Embed` macro delegate to it, and the macro no longer injects `require Logger` into hosts.
- ~~**IMPROVEMENT-HIGH** (Mistral) — document the "double-fire" scenario in `AITranslate.Embed` moduledoc.~~ Corrected in `34cb7aac` — the premise was inverted: `attach_hook` runs *before* the LV's own callbacks and the hook `:halt`s the AI events, so a host's own `{:ai_translation, …}` clause is **shadowed (never fires)**, not double-fired. The moduledoc documents the accurate shadowing behavior instead of the suggested warning.
- ~~**SUGGESTION** — CHANGELOG entry for the Leaf-forwarding fix.~~ Landed with the `1.7.132` release (`4640585e`).

## Skipped (with rationale)
- **SUGGESTION** — cross-reference the three documented moduledocs (`markdown_editor`, `media_gallery`, `media_selector_modal`). Cosmetic; low value vs. churn. Recorded as skipped in the reviews' Fix Status by the maintainer.
- **NITPICK** — `@doc false` on the hook-internal `__handle_event__/3` / `__handle_info__/2`. No action; the double-underscore naming signals intent and matches `MediaBrowser.Embed`. Both reviewers concurred none needed.

## Files touched
| File | Change |
|------|--------|
| (none this pass) | All fixes landed in maintainer commits `34cb7aac` / `d9a483a2` / `4640585e` before this after-action was written. |

## Verification
Fixes verified by the maintainer at fix time (`mix precommit` green per the `34cb7aac` / `d9a483a2` notes). The shared extraction (`CommentsForwarding`) is exercised by the integrated tree (compiles clean against local core; projects/staff Embed consumers green).

## Open
None.
