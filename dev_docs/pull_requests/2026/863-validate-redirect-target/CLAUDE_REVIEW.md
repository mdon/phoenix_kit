# PR #863 — Validate the full redirect target, not just replacement segments

**Author:** timujinne (Tymofii Shapovalov) · **Reviewer:** Claude · **Date:** 2026-09-24
**Verdict:** sound; merged into `main`. No code bugs found. One comment corrected.
Refs #849, follow-up to #861.

## What it does

The locale plug's redirects (`redirect_to_base_locale/2`, `redirect_invalid_locale/2`,
`redirect_default_locale_to_clean_url/2`) all build their target in
`locale_segment_path/3`. Before this PR, two kinds of input could make that target
something `Phoenix.Controller.redirect/2` refuses, which raised an `ArgumentError`
and turned an anonymous GET into a 500:

1. **A computed base code that spells an escape as text.** `/%2509-x/...` decodes once
   to `%09-x`, so `extract_base/1` gives the literal text `%09`. The old byte
   blocklist let that through, and `/%09` is on Phoenix's refusal list.
   **Fix:** `safe_path_segment?/1` is now an allowlist, `\A[a-zA-Z0-9_-]+\z`.
2. **Raw client `rest`.** It was never validated. `/zz/%09evil/shop` 500'd before #861
   too. **Fix:** `unsafe_redirect_target?/1` checks the fully joined path against
   Phoenix's own two checks (a leading `//`, and the substring list). It also rejects
   a `.`/`..` segment, raw or single-percent-encoded, so a client-supplied dot-segment
   can't resolve outside the mount once the browser has it.

When the target is rejected, the function returns `:error`, which every caller already
handles by rendering under the default or resolved-base locale. No control flow changed.

## Verification

- Read against `deps/phoenix/lib/phoenix/url.ex` (1.8.14). `classify_local_path/1`
  rejects `"//" <> _` and anything containing `["\\", "/%09", "/\t", "\n", "\r"]`. The
  mirror matches exactly, and the missing `\n`/`\r` entries were added (they also
  tighten `with_query_string/2`, which is correct).
- Callers' replacement segments: base codes, the default locale code, or `[]`.
  Every real code (`en`, `zh-Hant`, `sr_Latn`) passes the allowlist.
- `PGDATABASE=beamlab_test mix test test/integration/users/auth_locale_test.exs
  test/phoenix_kit_web/users/auth_test.exs`: **94 tests, 0 failures**. The 38
  integration tests really ran; none were excluded.

## Findings

### NITPICK — "singly or doubly" misdescribed the dot-segment decode (fixed)

The comment on `unsafe_redirect_target?/1` said a percent-encoded dot is caught
"singly or doubly". The code decodes exactly once more, so `%252E%252E` is (correctly)
not rejected: to a browser it isn't a dot-segment. The comment now says one extra
pass, and explains why that is enough.

### NITPICK — the Phoenix char-list mirror can drift (not fixed)

`@unsafe_redirect_chars` copies a list that is private to Phoenix (`Phoenix.URL` is
`@moduledoc false`). An older Phoenix within our `~> 1.8.1` range with a shorter list is
harmless: our list is a superset, so we only decline more. A **future** Phoenix that
adds a character would bring the 500 back for that character. Calling
`Phoenix.URL.classify_local_path/1` directly would depend on internal API, so the
mirror is the right trade-off. Re-check the list when bumping Phoenix.

### NITPICK — a debug log on every decline (not fixed)

`Logger.debug` logs `conn.request_path` whenever a target is declined. It's debug
level, and the request line can't carry raw control bytes, so this is fine.
