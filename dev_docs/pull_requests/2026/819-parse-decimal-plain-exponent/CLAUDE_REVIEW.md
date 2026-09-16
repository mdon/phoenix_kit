# PR #819 — `parse_decimal/2`: integers keep exponent 0, never `1E+1`

**Author:** timujinne (`fix/parse-decimal-plain-exponent`) · **Merged:** 2026-09-16 · **Reviewed:** 2026-09-16 (post-merge)

## Verdict

Correct and worth shipping. `Decimal.normalize/1` strips trailing zeros from
the integer part too, so `parse_decimal("10")` returned `1E+1`. That struct is
`Decimal.equal?/2` to `Decimal.new("10")` but not `==` to it, and
`to_string/1` / Jason print the exponent form. The new private
`plain_normalize/1` multiplies a positive exponent back into the coefficient,
and the parse paths and `format_decimal/1` now use it. The tests pin both the
`==` equality and the plain printing. One placement issue was fixed after the
merge. Released in 2.26.1.

## Verified premises

- **Integer and float inputs.** `parse_decimal(10)` goes through
  `Decimal.new/1` with `exp: 0`, so it was never affected. Floats route
  through the `%Decimal{}` clause, so they get the fix.
- **NaN/Infinity.** They carry `exp: 0`, so the `exp > 0` guard skips them,
  as the comment says. `parse_decimal` also rejects them before normalizing.
- **Zero.** `Decimal.normalize/1` of any zero returns `exp: 0`, and
  `unsigned_zero/1` still runs inside `bound/2`.

## Findings

### NITPICK — new comment merged into `normalize_decimal_text/1`'s comment block (FIXED)

`plain_normalize/1` was inserted between `normalize_decimal_text/1` and the
comment that describes it. The result was a single 13-line comment above
`plain_normalize/1` that started by describing space folding and separator
resolution, and `normalize_decimal_text/1` was left with no comment. The
comment now sits back above `normalize_decimal_text/1`. No code changed.

### Checked, not a problem — exponent expansion runs before the magnitude ceiling

`bound/2` rejects anything of 10¹² or more, but `plain_normalize/1` runs
first, so a programmatic `%Decimal{coef: 7, exp: N}` makes
`Integer.pow(10, N)` run before the rejection. I probed it:
`Decimal.normalize/1` applies the context's exponent limit and turns large
exponents into `Infinity` (for example `exp: 20_000_000` becomes `Infinity`,
which the guard skips). The largest expansion that gets through measured
about 1.5 ms (`exp: 1_000_000`). String input cannot carry an exponent at
all, because the shape regex rejects it. This case does not justify
reordering the guard.
