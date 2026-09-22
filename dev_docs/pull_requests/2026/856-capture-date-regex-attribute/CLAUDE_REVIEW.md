# PR #856: Build CaptureDate's file-name patterns in a function so 2.37.0 compiles on OTP 28

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`318bcb76`), released as 2.37.1; review only, no fixes applied (no BUG findings)
**Date**: 2026-09-22

## Goal

2.37.0 fails to compile on Elixir 1.18.4 / OTP 28 (#855):
`cannot inject attribute @filename_patterns into function/macro because cannot
escape #Reference<...>`. The V200 capture-date work put a *list* of `~r`
sigils in a module attribute read by `from_filename/1`; on OTP 28 a compiled
regex holds a reference, and that Elixir cannot escape one nested in a list.
The PR moves the list into a private `filename_patterns/0`.

## Verified

- Behaviour unchanged: the same four sigils in the same order, so
  `Enum.find_value/2` still prefers the most specific pattern first. The
  `from_filename/1` cases in `test/modules/storage/capture_date_test.exs`
  cover every pattern.
- The PR's "no other regex-list attribute" claim holds: a multiline search
  over `lib/` for `@attr [`/`%{`/`{` containing `~r` finds nothing else. The
  ~40 single-regex attributes (`@local_re`, `@offset_re`, `@quicktime_re` in
  the same file, etc.) are escaped by Elixir's top-level `Regex` special case
  and compile on the reporter's toolchain.
- Elixir 1.19.5 / OTP 28 (this sandbox) compiled the old list attribute fine
  — the failure is specific to 1.18 on OTP 28, which is why it slipped
  through the 2.37.0 gate.

## Findings

### NITPICK: no regression guard for the toolchain that broke

Nothing in the gate runs Elixir 1.18 on OTP 28, so a future regex-list
attribute would slip through the same way. A test cannot reproduce it on
1.19 (the old code compiles there). Not fixed — the guard would be a CI
matrix entry, and CI is manual-only; the comment above `filename_patterns/0`
records the rule for the next reader.

### NITPICK: sigils in a function body may be rebuilt per call on OTP 28

Depending on Elixir/OTP version a `~r` in a function body can be recompiled
at runtime on each call. `from_filename/1` runs once per upload / backfilled
file, at most four compiles — negligible next to the download and EXIF read
it sits behind. Not changed.
