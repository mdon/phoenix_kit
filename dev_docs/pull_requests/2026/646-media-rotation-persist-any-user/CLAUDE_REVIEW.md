# PR #646 — Persist media rotation for any user, not just admins

**Author:** Alexander Don (alexdont)
**Merged:** 8d4902d1 (into `main`)
**Reviewer:** Claude (post-merge)

## Summary of changes

- **`media_browser.html.heex`**: the popup's `MediaCanvasViewer` now mounts
  with `persist_rotation={true}` unconditionally, replacing
  `persist_rotation={@admin}`. The `Details` link stays gated on `@admin`
  (it targets the admin detail page and is unrelated to persistence).
- **`media_canvas_viewer.ex`**: comments updated to describe
  `persist_rotation` as an opt-in any host can take (browser popup + detail
  page both do; the gallery lightbox in `media_viewer.ex` still doesn't pass
  it, so it stays read-only/seed-only as before). No behavioral change here
  beyond the comment — the gating was always on whatever the host passed in.
- **Follow-up commit (07f4642d)**: `test/phoenix_kit_web/components/multilang_form_test.exs`
  — aliased `Phoenix.LiveView.Lifecycle` at the top of the module and swapped
  the three fully-qualified call sites to the short form. Unrelated to the
  rotation fix; needed to unblock `credo --strict` (which was flagging the
  fully-qualified references as aliasable) so `mix precommit`'s `quality.ci`
  chain reaches `dialyzer` at all.
- **Test**: `test/integration/phoenix_kit_web/components/media_browser_test.exs`
  — renamed `describe "rotation persistence in the admin popup"` to
  `"rotation persistence in the popup"`; the test body is otherwise
  unchanged (still exercised via an admin-authenticated session, since
  `/admin/media` is the only `MediaBrowser` host wired into the test suite).

## Rationale (from the commit message)

Rotation is stored in the file's own `metadata["rotation"]` — a shared,
per-file property every viewer sees, not a per-user preference. Gating the
*write* on `@admin` meant a non-admin who could open and rotate a file
through an embedded `MediaBrowser` (per `CLAUDE.md`, embeddable in any host
LV, not just `/admin/media`) would see the turn in their own session but it
would silently not stick — the next viewer (admin or otherwise) would see
the un-rotated original. The detail page (`media_detail.html.heex`) already
passed `persist_rotation={true}` unconditionally, so this brings the popup
in line with the page that was already doing the "right" thing.

## Findings

None in the PR's own diff. The design is sound: `persist_rotation` gates a
write to a file the *host* already chose to expose to this user (whatever
scoping `MediaBrowser`/`scope_folder_id` already applies is unchanged by
this PR) — there's no new read-access surface, only whether a rotation the
user could already perform gets saved past their own session.

**One test-coverage gap, not fixed (documented, not a regression):** the
updated test still authenticates as an admin and drives the change through
`/admin/media`, so it doesn't actually exercise a *non-admin* persisting a
rotation — the exact case the PR fixes. This isn't a gap introduced by this
PR (the comment in the test file is honest about it: "Exercised via the
admin route since that's the only in-suite `MediaBrowser` host") — there is
currently no non-admin-embedded `MediaBrowser` LiveView in the test suite to
drive it through. Left as-is; adding one would mean standing up a test host
LV solely for this assertion, which is more scaffolding than the fix
warrants. Worth revisiting if/when a real non-admin `MediaBrowser` embed
lands in the app (host apps already can do this today per `CLAUDE.md`, just
nothing in-suite exercises it).

## Verification performed

- Grepped every `persist_rotation` call site (`media_canvas_viewer.ex`,
  `media_browser.html.heex`, `media_canvas_viewer.html.heex`,
  `media_detail.html.heex`) — confirmed the popup and detail page are the
  only two hosts, both now `true`; `media_viewer.ex` (gallery lightbox)
  passes no `persist_rotation` at all, defaulting to `false` in `mount/1` —
  matches the updated comment's claim.
- Read `persist_rotation/3` (the private write helper) — it fetches the
  file fresh via `Storage.get_file/1`, compares against the current stored
  rotation (no-op skip), and writes via `Storage.update_file/2` with no
  additional authorization check of its own; the only gate is whether the
  host opted the viewer into persistence. Confirmed this is intentional and
  pre-existing (the detail page already worked this way) — not a new
  authorization hole introduced by widening the popup's opt-in.
  `handle_event("fresco:rotate", ...)` guards on `socket.assigns[:persist_rotation]`
  before calling it.
- Confirmed `@admin` is still referenced in `media_browser.html.heex`
  (`details_path={if @admin, do: ...}`) — no unused-assign/compiler warning
  from removing its use on the `persist_rotation` line.
- Diffed the `multilang_form_test.exs` follow-up: the alias is used at all
  three call sites that credo previously flagged as fully-qualified; no
  other change to test logic or assertions.

## Gate result

`mix precommit` (format --check-formatted, credo --strict, dialyzer):
**PASS** — 8853 mods/funs, credo found no issues, dialyzer clean.

## Release

Hex was already at the previously-published `1.7.201`; this PR's changes
were unpublished. Bumped to **1.7.202**, published via `mix hex.publish
--yes`, tagged `v1.7.202` after a successful publish.
