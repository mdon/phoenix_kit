# PR #924 — Modals: drag-release, kept textarea size, unsaved-input guard

**Author:** mdon (Max Don) · **Merged:** 2026-10-13 (34d9f2eca) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

Hand-written `priv/static/assets/phoenix_kit.js` gains: `backdropClick` (press AND release must land on the `<dialog>`), a
document-wide textarea-size keeper, a stray-click filter for a drag that starts in a text field, and `close_guard: :confirm`
(now the `<.modal>` default): the first Esc/backdrop attempt on a typed-into form is refused with a nudge, a second within 4 s
closes. Class-driven `.modal-open` modals get the same guard. `<details>` sections get
`phx-mounted={JS.ignore_attributes(["open"])}` so a patch no longer folds them. Also a `pkDialogDrafts` cleanup in `updated()`.

Verdict: sound; one edge case fixed, two minor items on record.

## Findings

- **IMPROVEMENT - MEDIUM (fixed)** — class-modal Escape handler walked *down* the `.modal-open` stack, skipping untouched and
  `PkDialog` modals, so a touched modal *underneath* an untouched top one swallowed the Escape meant for the top one (nudging
  the wrong box). Only the topmost modal answers now (`phoenix_kit.js`, keydown capture handler).
- **NITPICK (fixed)** — the `close_guard` line in `modal.ex`'s `@moduledoc` still described only `:input`.
- **NITPICK (open)** — a `PkDialog` whose form is submitted but stays open (add-another flows) keeps `_pkTouched`, so the next
  Esc needs two presses; the class-modal path clears it on `submit`, the PkDialog path does not. Harmless (never traps), left.
- **NITPICK (open)** — `keptSizesById` is never pruned; bounded by distinct textarea ids per page load, so fine in practice.

## Checked

- `phx-mounted` + `ignore_attributes` does not need an id; the ids the PR added to the danger-zone/instructions sections are
  still right for stable patching. Server-driven `open={@name == nil}` is now deliberately ignored after first render.
- A textarea auto-grow script would fight the size keeper — none exists in `lib/`/`assets` (the only `style.height` writes are
  the viewer/table code, unrelated to textareas).
- JS unit tests (`test/js/backdrop_click.test.cjs`) cover the pure helpers.
