# PR #925 — Boot reads every module beam once, not three times

**Author:** timujinne · **Merged:** 2026-10-13 (cf15a4d2b) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

`ModuleDiscovery.current_external_modules/0` answers from the last scan while a `stat` fingerprint of the code path is
unchanged; `ModuleRegistry.load_modules/0` uses it so `static_children/0`, `init/1` and `rescan/0` share one beam read.
`module_hash_fast/0` shares the same remembered scan (the memo gained a per-dir module map). `rescan/1` takes a 1-minute
timeout. The scan reads the clock first, so a file written mid-scan never passes as "settled".

Verdict: correct. No bugs found.

## Checked

- **Fingerprint coverage:** `.app` files and beams of dependent apps, plus every directory's mtime, so an added/removed beam or
  dep misses; `config :phoenix_kit, :modules` is both in the fingerprint and re-read by `assemble/2`.
- **Hot reload:** a rebuilt beam changes mtime/size → miss; a scan that saw a file younger than 2 s is not remembered.
- **Memo shape change** (3-tuple → 4-tuple) falls through the `with` as a plain miss, so a reloaded module never crashes on an old memo.
- **Failure policy:** `scan_now/0` falls back to `discover_external_modules/0`; `remembered_scan/0` and `module_hash_fast/0` rescue to a slow-but-correct answer.
- Code-path ORDER is deliberately outside the fingerprint (dev VMs reorder it per compile) and re-applied by `assemble/2`.
