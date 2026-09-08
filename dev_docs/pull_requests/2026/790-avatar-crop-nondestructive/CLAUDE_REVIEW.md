# Claude Review — PR #790

**Title:** Add non-destructive avatar cropping, Apple Photos style
**Author:** alexdont
**Merge commit:** ba4c14c5
**Verdict:** Approve — no further fixes needed

## Summary

Adds non-destructive avatar cropping (`PhoenixKit.Users.AvatarCrop`): a crop is
stored as `%{"x", "y", "zoom", "ar"}` in `custom_fields["avatar_crop"]`, never
re-encoded pixels — the original upload is untouched. Picking a file now opens
a crop editor (drag/wheel/slider) before anything persists; rendering applies
the geometry as inline CSS on the shared `<.user_avatar>` component and the
admin `user_form.html.heex` preview.

## Review scope

The author ran their own multi-angle review before merge and pushed a fixup
commit (`57777814`) claiming five defects fixed (see the PR's GitHub comments).
This review independently re-verified each of those five claims against the
current merged code — tracing call sites rather than trusting the commit
message — and read the full changed files (`avatar_crop.ex`, `custom_fields.ex`,
`user_settings.ex`, the crop hook in `phoenix_kit.js`) for anything the
author's own pass missed.

## Findings

### Author's five claimed fixes — all CONFIRMED

1. **Stale crop outliving its file** — `auth.ex:2098-2126`,
   `maybe_update_custom_fields/2` calls `drop_stale_avatar_crop/3` as the single
   choke point every avatar write funnels through: the settings LiveView, the
   admin user form, and `Auth.update_user_avatar/4` all converge here via
   `update_user_fields`. `test/integration/users/avatar_crop_stale_test.exs`
   exercises the choke point directly.
2. **Landscape sharpness** — `avatar_crop.ex:196-202`, `variant_for/3` now
   scales by `max(ar, 1.0)` against image width, so a wide image's short side
   (height) is what bounds sharpness; portrait stays factor 1 since width was
   already the short side.
3. **Wheel-zoom / Save race** — `phoenix_kit.js:7611-7622`, the save-button
   listener is registered with `capture: true` and flushes the debounced push
   synchronously before the bubble-phase `phx-click` fires, so the final zoom
   value is queued ahead of the save event.
4. **Unguarded `open_avatar_crop`** — `user_settings.ex:477-490` now guards on
   `avatar_file_uuid` presence before opening the modal.
5. **Identity crops persisted on the adjust path** — `save_avatar_crop`
   (`user_settings.ex:506-528`) calls `AvatarCrop.drop_identity/1` on both the
   fresh-pick and adjust branches.

### NITPICK — moduledoc interpolates a literal

`avatar_crop.ex:78`'s `@moduledoc` interpolates `#{inspect(8.0)}` next to the
literal `@max_zoom 8.0` two lines below. Compiles fine, just reads oddly; a
plain `8.0` would be clearer. Not worth a standalone fix.

## Not a concern

- No new `phx-change` forms were added (the crop editor is button/click-driven),
  so the repo's missing-`id` form-recovery gotcha doesn't apply.
- No PubSub touched.
- The OAuth avatar path (`oauth.ex:238-251`) uses a separate
  `oauth_avatar_url` key and never writes `avatar_file_uuid` over an existing
  custom avatar, so it cannot trigger the stale-crop path — correctly out of
  scope for the invariant.

## Verification

- `mix test test/phoenix_kit/users/avatar_crop_test.exs test/phoenix_kit_web/components/core/user_avatar_crop_test.exs` — 25 tests, 0 failures.
- DB-backed integration test (`avatar_crop_stale_test.exs`) and the JS test
  (`test/js/avatar_crop.test.cjs`) verified separately as part of the release
  gate rather than in this review pass.
