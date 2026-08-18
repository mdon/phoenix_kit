# PR #726 — Fix Sitemap.regenerate/1 returning a "not implemented" placeholder

Merge commit: `a83ab0e4` (diff `ca965a00`) · Author: timujinne · Reviewed by: Claude

Files in scope: `lib/modules/sitemap/sitemap.ex`, `test/integration/sitemap/regenerate_test.exs`.

## Summary

`Sitemap.regenerate/1` previously returned a hardcoded "not implemented" error. This
PR wires it to the real `Generator` call already used elsewhere in the module
(matching the pattern in `lib/modules/sitemap/web/controller.ex`), so the documented
public contract actually does what its `@doc` example claims.

## Review

`regenerate/1` isn't called anywhere else in `lib/` besides its own doc example, so
blast radius is limited to external/host callers relying on the documented contract
— exactly what this PR fixes. `regenerate_test.exs` asserts real regenerated output,
not just "no longer pending". Doesn't touch the source-collection path, so the two
known pre-existing sitemap issues (3× group-walk, flat-mode force-collect) are
unaffected.

## Findings

**NITPICK (pre-existing, not introduced by this PR)** — `sitemap.ex` around
`get_base_url/0` (line ~277) defaults to `""` via
`settings_call(:get_setting_cached, ["site_url", ""])` when `site_url` isn't
configured, while `Generator.generate_all/1` only guards against `is_nil(base_url)`.
An unconfigured install would silently produce malformed (host-less) URLs instead of
`{:error, :base_url_required}`. This PR just makes `regenerate/1` match the identical
pre-existing pattern already used by `web/controller.ex:125` — not a regression from
this diff. Worth a future `is_nil(base_url) or base_url == ""` fix, tracked here but
out of scope for this review.

## Verdict

No bugs found. Clean, low-risk fix. No fix applied.
