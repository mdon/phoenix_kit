# PR #861 — Fix infinite redirect loop for non-ASCII locale segments

**Author:** timujinne · **Merged:** 2026-09-23 (229c1816) · **Reviewer:** Claude · **Released in:** 2.37.5 · **Fixes:** #849

## Summary

The three locale redirect helpers in `PhoenixKitWeb.Users.Auth`
(`redirect_default_locale_to_clean_url/2`, `redirect_to_base_locale/2`,
`redirect_invalid_locale/2`) built their target with `String.replace` on
`conn.request_path`. That path stays percent-encoded, but the locale they
were given is the decoded `path_params` value. For `/дордол` the replace
matched nothing, so the "corrected" URL was the request URL and the browser
looped.

All three now go through one positional helper, `locale_segment_path/3`.
It is the old `strip_locale_segment/2` with a list of replacement segments
added. It matches decoded segments, emits the rest of the path raw, and
returns `:error` when the locale is not the segment right after the
configured `url_prefix`. Each caller redirects only when the new path
differs from `request_path`. Otherwise it renders under a fallback locale,
un-halted. `redirect_invalid_locale/2` also gains `with_query_string/2`
(it used to drop the query). A `safe_path_segment?/1` guard stops a crafted
dialect (`//evil.com-x`, `\x`, a control character, `-x`) from reaching
`Phoenix.Controller.redirect/2`, which raises on those.

Verdict: correct and well tested. The loop is closed for every helper, not
just the one in the issue. One finding in the new no-redirect branch, fixed
below.

## Findings

### BUG - MEDIUM — the no-redirect branch of `redirect_to_base_locale/2` rendered under any language

When no redirect can be built, the PR keeps the requested dialect's base
(`/…/fr-CA` renders in French) rather than dropping to the site default.
The only check in front of it was `safe_path_segment?/1`, which asks
whether the text is safe to put in a path, not whether it is a language.
So:

- `zz-QQ` rendered with `current_locale_base == "zz"` and Gettext locale
  `"zz"`. A bare `/zz/...` goes to `redirect_invalid_locale/2` instead.
- `fr-CA` with French disabled rendered in French. A bare `/fr/...` is
  redirected to the default instead.
- Any other segment that passes the path check (`<b>-x`) also landed in
  `current_locale_base`, and link builders read that value back.

This branch runs whenever the dialect is not where `url_prefix` puts it.
One real case is `phoenix_kit_publishing`'s `:language` routes, which
`process_locale/1` also reads.

**Fix:** the fallback keeps `base_code` only if
`DialectMapper.valid_base_code?/1` and `locale_allowed?/1` both pass. That
is the same check `process_locale/1` runs before `process_valid_locale/2`.
Anything else falls back to `assign_default_locale/1`. The moduledoc
section "When it does not redirect" and the comment on
`assign_resolved_base_locale/2` are updated to match. Three integration
tests in `auth_locale_test.exs` (en + es enabled) cover it:
`es-MX` → `es`, `fr-CA` → `en`, `zz-QQ` → `en`. The last two fail against
the PR as merged.

### NITPICK — a non-ASCII base is written raw into `Location`

For a dialect like `ру-RU` (not a real language, but it reaches this
function), `base_code` is spliced into the redirect target unencoded, so
the `Location` header holds raw UTF-8 bytes. Browsers percent-encode it as
UTF-8, and the next hop (`/ру/...`) goes to `redirect_invalid_locale/2`
and lands on the default, so nothing loops. Not changed. Percent-encoding
the replacement segments in `locale_segment_path/3` would make the header
pure ASCII if a proxy ever objects.
