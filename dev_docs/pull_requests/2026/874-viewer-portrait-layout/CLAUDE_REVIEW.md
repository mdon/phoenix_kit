# PR #874 — Update the viewer to lay itself out by shape, not by width

**Author:** alexdont (Sasha Don) · **Reviewer:** Claude · **Date:** 2026-09-25
**Verdict:** sound; released in 2.40.0. A light review, done while cutting the
release: the PR was merged on `main` just before it.

The popup's side split now needs `lg:landscape:` instead of `lg:` alone, so a
portrait window at desktop width gets the stacked layout mobile already used.
Stacked, the picture pane takes the picture's aspect ratio (`pane_aspect/2`,
with a quarter turn swapping the axes) instead of a share of the popup's
height, and `ViewerPaneFit` corrects it from the bitmap on screen (a burned copy
can be a different shape). The instant stand-in and prev/next stepping carry
the neighbour's ratio so the box does not jump.

Checked: every change is behind `lg:portrait:` or `lg:landscape:`, so a
landscape desktop window renders as before. `neighbor_pane_aspect/1` passes a
row's rotation, which may be `nil`; `normalize_rotation/1` already maps that to
0. A file without dimensions gets `nil` and the old fixed share. The PR's
Elixir tests (22) and the JS tests pass on `main`.

No findings in the code. **Missed in this review:** #874 moved the
sidebar's width cap to `lg:landscape:`, and `viewer_sidebar_width_test.exs`
still looked for `lg:max-w-`, so it failed on `main` and in 2.40.0 (only
the PR's own tests were run here, not the full suite). The test is updated
in 2.40.1; the behaviour it guards (one cap, shared by the real sidebar and
the stand-in) still holds.
