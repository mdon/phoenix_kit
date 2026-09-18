# PR #827 — Core PreviewCard: the catalogue product card render as a reusable core modal component

**Author:** Timujeen (`feat/preview-card`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

11 files: a new `lib/phoenix_kit_web/components/core/preview_card.ex`
(`preview_card/1` + `preview_card_body/1`, 337 lines), a 191-line render-shape
test, and three new msgids across `priv/gettext`.

## Verdict

Clean extraction. The component is genuinely pure — worth stating, because the
moduledoc claims it and the claim is load-bearing for the test suite:
`URLSigner.signed_url/3` builds its path from an HMAC token and
`Routes.path/2` with no repo access (`lib/modules/storage/services/url_signer.ex:56`),
so "testable without a database" holds. One NITPICK fixed, two notes.

Checked and correct:

- **Carousel indexing.** The jump strip offsets files by `length(@images)`
  (`Enum.with_index(@files, length(@images))`), and the track renders images then
  files in that same order, so `jump_js(idx)`'s `t.children[idx]` addresses the
  right slide for both halves. The PDF-plus-tile case renders two children inside
  *one* `carousel-item`, so it does not shift the count.
- **The inline JS survives navigation.** These are `onclick`/`onscroll`
  *attributes*, not a `<script>` tag registering a hook — morphdom patches
  attributes, so the landmine in AGENTS.md ("never register a JS hook from an
  inline `<script>`") does not apply here. The arrows and strip keep working after
  a `live_redirect`.
- **No injection surface in the generated JS.** `jump_js/1` interpolates an
  integer index and nothing else; every other value reaches the DOM through HEEx
  attribute escaping.
- `file_ext/1` degrades to `"file"` for a nil or extension-less name rather than
  raising, and `format_size/1` to `""` for a nil or zero size.

## NITPICK — `preview_card_body/1` required a `:target` it never reads *(fixed)*

The body declared `attr(:target, :any, required: true)` and `preview_card/1`
dutifully forwarded it, but the body's template never references `@target` — it
renders no events at all (slide switching is client-side; the only server event,
Close, lives in the modal's action row, which belongs to `preview_card/1`).

That matters slightly more than a dead attr usually would, because
`preview_card_body/1` is documented as the public "notpopup" form for inline
embedding: every such embedder was required to pass a value that does nothing.
Dropped the attr and the forwarding, and said so in the body's `@doc`. Nothing
consumes the component yet (the catalogue delegation is the announced follow-up,
and it calls `preview_card/1`), so this is free to do now and would not be later.

## IMPROVEMENT - MEDIUM — the image URLs are unversioned, so they are never cached for good

Every `URLSigner.signed_url(uuid, variant)` call here omits `version:`. Per
AGENTS.md ("Storage & Image Editing") only a versioned URL is served with a
year-long `immutable` lifetime; an unversioned one is revalidated on every view.
For a card whose whole job is showing the same photos repeatedly, that is a real
miss.

**Not applied deliberately.** The caller hands in `%{uuid, name}` maps with no
checksum, so the component has nothing to version *with*, and inventing an
optional `:checksum` key now would be adding public API surface for a caller that
does not exist yet. The right moment is the catalogue-delegation follow-up, which
owns `resolve_images/1` / `resolve_files/1` and does have the instances at hand:
have those resolvers carry the checksum and pass
`version: Map.get(img, :checksum)` through — `URLSigner.version/1` already returns
`nil` for anything it does not recognise, so the change is backwards compatible
by construction. Recorded here so the follow-up does not have to rediscover it.

## Note — `onscroll` is the only thing keeping the strip in sync

The active-tile highlight is computed from `Math.round(scrollLeft/clientWidth)` in
a debounced inline handler. It is correct for the normal case and cheap, but it
divides by `clientWidth`, which is `0` while the modal is still closed — the
result is `NaN`, `Array.forEach` then marks nothing active, and the strip simply
keeps its server-rendered "tile 0" state until the first real scroll. Harmless,
and the server-side default is the right fallback, so no change. Flagged only
because a future move to a scroll-driven *server* event would not be so forgiving.
