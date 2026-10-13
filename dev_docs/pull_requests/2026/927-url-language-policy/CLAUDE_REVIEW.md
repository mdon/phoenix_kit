# PR #927 — Primary language outlives the multi-language switch; single-language sites emit no locale segment

**Author:** timujinne · **Merged:** 2026-10-13 (8f06da980) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

New `Languages.primary_language_code/0`, `configured_primary_language_code/0`, `set_primary_language/1`, `single_language?/0`,
`single_language_safe?/0`; a "Primary language & URLs" card that stays visible with the switch off; `Routes` emits no locale
segment for any locale on a single-language site; the locale plug redirects a segment away (302, 307 for non-GET/HEAD); the
LiveView locale hook agrees; hardcoded `"en"`/`"en-US"` fallbacks (sitemap sources, `Multilang`, `Settings`) now use the
primary language. First switch-on seeds `default_language_no_prefix` so a clean-URL site keeps clean URLs.

Verdict: coherent and well tested; one regression fixed.

## Findings

- **BUG - MEDIUM (fixed)** — `Settings.get_content_language_details/0` on a site with nothing configured (switch off, no
  stored config — the most common state) returned `%{code: "en", name: "en", native: "en"}` instead of English: it looked the
  bare base `"en"` up with `get_predefined_language/1`, which only knows full locales (`get_locale("en")` is `nil`; `"uk"`
  works). The base is now looked up under the `default_locale` it was derived from. Test strengthened to assert the name.

## Checked

- Dispatch order in `process_valid_locale/2`: single-language non-admin → strip segment (307 for POST so login bodies survive),
  admin → render as typed under the primary language. An invalid locale on a single-language site is stripped rather than swapped.
- `single_language_safe?/0` follows `prefixless_primary_safe?/0`'s failure policy (mix task / DB error → multilingual shapes, which still route).
- `set_primary_language/1` validates through `get_predefined_language/1`, so the event's `code` param cannot store junk; a language
  chosen while the switch is off is restored on a later switch-on.
- `seed_prefixless_primary/0` runs before the config save; if that save fails the setting stays seeded — harmless (idempotent, explicit values are never overwritten).
