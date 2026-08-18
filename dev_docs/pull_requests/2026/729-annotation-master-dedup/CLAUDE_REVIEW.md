# PR #729 — Fix the master comment repeating the shape's label, and update etcher to 0.13.1

Merge commit: `8349565a` (component commits `f424f520`, `b15f88a8`) · Author: alexdont ·
Reviewed by: Claude

Files in scope: `lib/phoenix_kit_web/components/media_canvas_viewer.ex`, `mix.lock`,
`priv/static/assets/phoenix_kit.js`.

## Summary

Two independent changes:

1. A labelled annotation shape's master comment (the thread's topic row) used to
   repeat the shape's label as the comment's content, even though the sidebar
   already renders the label as the thread's heading — every thread opened by
   saying the same thing twice. Fixed by creating the master with empty content for
   labelled shapes, via a new `allow_empty_content: true` attr passed to
   `PhoenixKitComments.create_comment/4`.
2. etcher bumped 0.13.0 → 0.13.1 (tooltip anchor box fix), `mix.lock` and the CDN
   pin in `priv/static/assets/phoenix_kit.js` moved together.

## Review

### etcher bump — checks out, no issue

`mix.lock` and the sole CDN pin both moved to v0.13.1 together; no third pin
location exists. `test/phoenix_kit_web/vendored_cdn_pins_test.exs` guards exactly
these two locations.

### `allow_empty_content` — the "clean fallback" claim was false

**BUG - CRITICAL (fixed)** — `create_master_comment/2` sent `content: ""` for every
labelled shape, relying on `allow_empty_content: true` to be honored by
`phoenix_kit_comments`. The PR description claims this degrades gracefully against
an older `phoenix_kit_comments`: *"the flag is an unknown attrs key to older
versions, so the master simply keeps the label as content (the pre-fix behavior)"*.

That's not what happens. `phoenix_kit_comments` is not a dependency of this repo
(it's the reverse — an optional sibling module loaded at runtime via
`Code.ensure_loaded?/1`), so there is no version of it pinned here to verify against
in-repo. Checked the actual `phoenix_kit_comments` source directly (workspace
checkout at `main`, `dc0aa28`, version `0.4.1` — matches the latest Hex release,
confirmed via `hex.pm/api/packages/phoenix_kit_comments`) and grepped its full
history and all branches: **`allow_empty_content` does not exist anywhere** — not on
`main`, not on any branch, not published. It was apparently planned ("comments PR
incoming") but never shipped.

`do_create_comment/4` casts attrs and runs `run_cheap_validators/2` →
`validate_has_body/2`, which has no knowledge of `allow_empty_content` — an unknown
attrs key is simply dropped, not treated as a capability flag. With `content: ""`
and no giphy/no attachments, `validate_has_body/2` returns
`{:error, :empty_comment}}` unconditionally. `create_master_comment/2` treated any
`{:error, _}` as a hard failure, so `ensure_master_comment/2` returned `:error`, and
the `with` in the `annotation_reply` event handler fell through to
`{:noreply, socket}` with no user-visible feedback.

**Net effect: pressing Reply on any labelled annotation shape silently did nothing**,
against the only `phoenix_kit_comments` version that currently exists anywhere
(0.4.1) — not a fallback to old behavior, a full break of the reply flow. This
directly contradicts the PR's "live-verified in a host app" and "3745 tests green"
claims; nothing in the diff exercises `annotation_reply` end-to-end against a real
`phoenix_kit_comments` install.

**Fix applied** — `media_canvas_viewer.ex`, `create_master_comment/2`: on
`{:error, :empty_comment}` specifically (and only when the shape has a title, i.e.
only on the bodiless path), retry once with `content: master_content(ann)` and no
`allow_empty_content` — the actual pre-fix behavior. This makes the PR's stated
intent true: works today against 0.4.1 (retries transparently), and once
`phoenix_kit_comments` ships real support for the flag, the primary bodiless attempt
succeeds and the retry path never triggers.

**IMPROVEMENT - NITPICK (fixed)** — `stored_title/1` treated an empty-string
`"title" => ""` in stored metadata as a present title (`is_binary("")` is true),
which would hit the same `:empty_comment` path via `master_content/1`'s
`stored_title(ann) || fallback` (`""` is truthy in Elixir, so the fallback never
fires). In practice this can't currently happen from the UI — `persistable_attrs/2`
always stores whatever `wire_title/1` produces, and `wire_title/1` already trims and
normalizes an empty/whitespace-only title to `nil` before it's persisted — but
`stored_title/1` didn't apply the same normalization to what it reads back, so the
two functions disagreed on what counts as "no title". Fixed by mirroring
`wire_title/1`'s trim-to-`nil` normalization in `stored_title/1`, which also fixes a
latent inconsistency in `annotation_unchanged?/2`'s comparison (a stored `""` would
never have compared equal to a wire-side `nil` for the same effectively-untitled
shape).

### Test coverage — not added here, documented instead

No test exercises `create_master_comment/2` or the `annotation_reply` event against
a real `PhoenixKitComments.create_comment/4`, before or after this fix.
`create_master_comment/2` is private, reachable only through the full LiveView event
with a real DB — and `phoenix_kit_comments` isn't a dependency of this repo at all
(confirmed above), so there is no way to exercise the real
`{:error, :empty_comment}` retry path from phoenix_kit's own test suite without
either introducing a fake `PhoenixKitComments` module into `test/support` (which
would change `Code.ensure_loaded?(PhoenixKitComments)` results for every other test
in the suite — `annotations.ex`, `comments_forwarding.ex`,
`media_browser/embed.ex`, etc. — a much larger and riskier change than this fix
warrants) or adding an integration test in a host app that actually depends on
`phoenix_kit_comments`. Recording this gap here rather than papering over it with a
test that doesn't actually exercise the failure mode.

## Verdict

One CRITICAL regression found and fixed (Reply silently broken for every labelled
shape against the real `phoenix_kit_comments`), plus a related nitpick fixed
alongside it. etcher bump is clean.
