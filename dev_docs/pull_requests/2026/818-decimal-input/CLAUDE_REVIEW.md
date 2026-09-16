# PR #818 — Add `<.decimal_input>` and `Number.parse_decimal/2` for free decimal form fields

**Author:** timujinne (`feat/decimal-input`) · **Merged:** 2026-09-16 · **Reviewed:** 2026-09-16 (post-merge)

## Verdict

A sound, well-bounded addition. The premise is real: `Decimal.parse("2,5")`
returns `{2, ",5"}`, and a browser number control drops text in the "wrong"
locale separator. The parser is strict about dot/comma grouping (3-digit
groups only), rejects exponents before any arithmetic, and caps input length
before the regexes run. Probing turned up one real gap, where space grouping was
not held to the rule dot and comma grouping follows, and one display
wart. Both were fixed post-merge. Released in 2.26.0.

## Summary of the PR

- `PhoenixKit.Utils.Number.parse_decimal/2` / `parse_decimal!/2` /
  `format_decimal/1`: comma or dot decimal point, space / dot / comma
  grouping, sign, `:min` / `:max`, a 10¹² magnitude ceiling, a 64-byte input
  cap.
- `PhoenixKitWeb.Components.Core.DecimalInput.decimal_input/1`:
  `type="text" inputmode="decimal"`, FormField or raw name/value, an optional
  `unit` suffix, and the same label/error/`class`/`wrapper_class` contract as
  `<.input>`. Imported through `PhoenixKitWeb`.
- Unit tests for both.

## Verified premises

- `"5\n"`: PCRE `$` matches before a trailing newline, so the shape regex
  passes it. The `{decimal, ""} <- Decimal.parse(...)` clause still rejects
  it, so nothing gets through.
- Oversized `%Decimal{}` exponents (`Decimal.new(1, 1, 1_000_000)`) are
  rejected by the ceiling in microseconds, with or without `:max`. Text can
  never carry an exponent.
- The component mirrors `Core.Input` (`phx-feedback-for`, `translate_error/1`,
  `assign_new(:name, ...)`), so the two stay consistent.

## Findings

### BUG - MEDIUM — Space grouping was never validated; typos silently merged into one number — FIXED

Dot and comma grouping must sit between 3-digit groups (`"1,23,4"` is
`:invalid`, "a typo, not a number"). Spaces, though, were stripped everywhere
before that check ran:

| typed | before | after |
|---|---|---|
| `"12 34"` | `1234` | `:invalid` |
| `"1 2 3"` | `123` | `:invalid` |
| `"1,234 567"` | `1.234567` | `:invalid` |
| `"1,5 25"` | `1.525` | `:invalid` |

In a quantity or price field, a silently wrong value is worse than a
validation error. Spaces are now folded to one ASCII space and trimmed, the
dot/comma resolution runs as before, and `ungroup_spaces/1` then holds the
remaining spaces to the same `ungroup/2` rule on the integer part. A space in
the fraction is `:invalid`. `"1 234,56"`, `"1 234 567"` and
`"-1 234,56"` still parse. Two inputs that used to parse are now rejected: a
sign detached by a space (`"- 5"`), and spaces mixed with a dot/comma grouping
(`"1 234.567,89"`). Both are rare typing patterns.

### NITPICK — Negative zero echoed back as "-0" — FIXED

`"-0"`, `"-0,0"`, `-0.0` and `Decimal.new("-0")` returned a negative-zero
`Decimal`, and `format_decimal/1` rendered it as `-0` in the field. `bound/2`
now returns an unsigned zero.

### NITPICK — Doc said "characters", guard counts bytes — FIXED

`byte_size(raw) > 64` rejects on bytes. The doc now says bytes. It makes no
practical difference: a no-break space is 2–3 bytes, and a legitimate value is
far under the cap.

### NITPICK — Small simplifications — FIXED

- The magnitude check did `gt?` and then `equal?`, which is two decimal
  comparisons. It is now one `Decimal.compare(...) != :lt`.
- `count_char/2` split the text into graphemes to count an ASCII byte. It now
  uses `:binary.matches/2`, like `last_index/2` beside it.

### IMPROVEMENT - MEDIUM — Component guide didn't mention the new primitive — FIXED

`dev_docs/guides/2026-09-11-core-components.md` is the "read this before
building admin forms" doc. It now says to use `<.decimal_input>` +
`parse_decimal/2` rather than `<.input type="number">`, and why.

### Not changed

- `"1,234"` / `"1.234"` parse as `1.234`, not `1234`. A single separator is
  the decimal point, as documented. That is the right call for European
  keyboards, and a US user writing `1,234` gets a small value they can see
  rather than an error. Kept as designed.
- `"2."` / `"1,234."` parse (trailing point). Harmless.
- `phx-feedback-for` is a no-op on LiveView 1.x, but `Core.Input` still
  carries it. Removing it belongs in a sweep across all form primitives, not
  in this component alone.
