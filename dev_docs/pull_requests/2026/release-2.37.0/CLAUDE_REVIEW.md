# Review of Grok's 2.37.0 pre-release fixes

**Commits:** `f5d5877a` (Fix the 2.37.0 pre-release review findings), `7bab4456` (lib upgrades).
**Reviewer:** Claude, 2026-09-22.
**Verified:** full `mix test` against PostgreSQL, integration included (6270 tests, 0 failures), which Grok could not run. `mix precommit` clean.

**Verdict:** ship after the fix below. One regression, fixed in the follow-up commit. The other fixes hold.

## BUG - HIGH (fixed): a module-wide tab lost its own landing page

`lib/phoenix_kit_web/users/auth.ex`, `infer_permission_from_custom_tabs/2`.

The H2 fix moved the bare-module cache entry behind the action-specific entries. A bare entry is not only a leftover. It is what a tab registered as `live_view: Mod` or `{Mod, nil}` caches: the module-wide key. With that tab (`"reports_view"`) plus one `{Mod, :edit}` tab (`"reports_manage"`), `:index`, `:show` and a `nil` action all resolved to `"reports_manage"`. Before the commit they resolved to `"reports_view"`. That breaks access both ways. A `reports_view` holder loses the list, and a `reports_manage`-only holder gets it. I reproduced it on both trees.

Fix: the order is now exact `{module, action}`, then the bare module, then the tabs' one shared key. If the tabs disagree the action stays `:unmapped`. If nothing is cached it's a `:miss`, which falls through to namespace inference. The part of H2 that mattered is kept: tabs that disagree no longer fall through to namespace inference. Grok's test "a bare-module entry does not authorize an untabbed action when the tabs disagree" pinned the regression. I replaced it with "a module-wide tab guards the actions no other tab names". The CHANGELOG entry is corrected.

## Checked, no change

- **Rotated burn (H1).** `burnContainerToImage` inverts `t + s·R·p` correctly. `burnSvgMatrix` is the matching SVG `matrix(a,b,c,d,e,f)`. It assumes no mirror or skew; the third sampled point is only null-checked.
- **Step burns (M1).** An arrow key that doesn't actually step (list edge) still calls `burnIfChanged`. That's harmless, because it's signature-gated.
- **Readonly reply (M3), no-store denials (M4), tile gate (M5).** Correct. The tile gate adds one `get_file` per manifest and tile request (`tile_source` reads the file again). Negligible, and the gate is off by default.
- **Backfill (M6).** Residual: when the backup's own download fails (`key` nil, `source_uuid` = backup), the filename date is still written and sticks. That's the same as any failed download before this commit, so it isn't a regression. It's only worth revisiting if backup reads turn out to fail in practice.
- **ffprobe epoch (M7), clone and `store_file/2` dates (M8).** Correct. `store_file/2` now runs EXIF / ffprobe inside the upload request for comment attachments. It's bounded, and the fallback is the filename or the upload time.
- **`7bab4456`.** Lock-only bumps: h2 0.12.1, quic 1.10.0, webtransport 0.4.6 (hackney transitive). They don't reach hosts' resolution constraints.
