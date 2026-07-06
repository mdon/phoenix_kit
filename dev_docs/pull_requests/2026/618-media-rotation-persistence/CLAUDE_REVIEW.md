# PR #618 — Persist image rotation in the media viewer

- **Branch:** `alexdont/feat/media-rotation-persistence`
- **Author:** Alexander Don (alexdont)
- **Merge:** `6db9086e` (feature commit `3e45228e`)
- **Version:** no bump in the PR; shipped in the 1.7.176 release cut alongside #619.
- **Reviewer:** Claude (Opus 4.8)

## Summary

Rotating an image in the admin media viewer now saves the angle to the file
row's `metadata["rotation"]` and restores it on the next open, via fresco 0.8's
opt-in `persist_rotation` server bridge. `MediaCanvasViewer` seeds
`initial_rotation` from the saved value for **every** viewer (public galleries
show the saved orientation too) and handles the new `"fresco:rotate"` event to
persist — guarded so only admin-context hosts (`MediaBrowser` modal gated on
`@admin`; the admin-only media-detail page) write to the shared row.

**Overall: clean, correct, no changes required.** No CRITICAL/HIGH/MEDIUM bugs
found. The LiveComponent lifecycle, the Fresco payload contract, the persistence
guard, and the admin gating all check out. Findings below are informational.

## Verification performed

- **LiveComponent, not LiveView.** `MediaCanvasViewer` is a `:live_component`;
  the rotation seed (`load_saved_rotation/1`) lives in the `update/2`
  `viewer_canvas == nil` first-mount branch. Because the DOM id encodes the file
  uuid, prev/next remounts a fresh component, so the branch runs once per open —
  no double-query concern (the Iron Law targets `LiveView.mount/3`, which does
  not apply here).
- **Fresco payload is always an integer in `{0,90,180,270}`.**
  `deps/fresco/priv/static/fresco.js` normalizes via `Math.round(deg/90)*90`
  before emitting `"rotate"`; the hook forwards `%{"rotation" => deg}` only when
  `data-persist-rotation="true"`. So the Elixir `normalize_rotation/1` never
  actually receives a float — but it is still correct defensive code, and its
  `Integer.mod(deg, 360)` path also folds 360°/negative angles back into the
  snapped set. **No risk of a float collapsing a saved rotation to 0.**
- **`Storage.update_file/2` is side-effect-free** — a plain
  `changeset |> repo().update()`, no PubSub broadcast and no activity log. The
  `current == rotation` guard in `persist_rotation/3` skips the DB round-trip on
  Fresco's Reset-view snap-back (which re-fires `rotate` at the home angle), so
  only genuine changes write.
- **`File` schema has `field :metadata, :map`** and it is cast in
  `File.changeset/2`, so `update_file(file, %{metadata: merged})` persists.
- **Admin gating is sound.** `MediaBrowser` modal passes `persist_rotation={@admin}`;
  `media_detail.html.heex` passes `persist_rotation={true}` unconditionally, but
  its route `/admin/media/:file_uuid` (`Live.Users.MediaDetail`) sits inside the
  core admin route block — non-admins can't reach it. Public gallery viewers seed
  `initial_rotation` but never persist.

## Findings

### NITPICK — two `Storage.get_file/1` reads across the rotate lifecycle

`load_saved_rotation/1` (in `update/2`) and `persist_rotation/3` (in the
`"fresco:rotate"` handler) each fetch the file. This is **not** redundant: they
run at different lifecycle moments, and the re-fetch in `persist_rotation/3` is
necessary — the assigned `:file` is a curated map (`%{file_uuid, ...}`), not the
`%Storage.File{}` struct `update_file/2` needs, and re-reading also picks up the
freshest `metadata` for the change-detection guard. No action.

### NOTE — rotation is a shared, not per-user, orientation

By design the angle lives on the file row, so an admin rotating an image changes
the saved orientation for every viewer (including public galleries). The commit
message and moduledoc call this out explicitly; flagged here only so it's on
record as intended behavior, not an oversight.

## Positives

- Correct opt-in split: display-everywhere (`initial_rotation` seeded for all
  hosts) vs persist-only-in-admin — matches the "shared file row, not a per-user
  preference" model.
- `handle_event`/`persist_rotation`/`load_saved_rotation` all rescue and fall
  back to `0` / no-op, so a DB hiccup never crashes the viewer.
- `phx-update="ignore"` on the canvas means re-passing `initial_rotation={@viewer_rotation}`
  after a persist cannot cause a re-render/rotate feedback loop.
