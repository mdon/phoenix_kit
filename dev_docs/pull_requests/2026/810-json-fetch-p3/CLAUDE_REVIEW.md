# PR #810 — Fix settings cache miss-fill and restricted-key nil caching

**Author:** timujinne (`i157-json-fetch-p3`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Correct, and it fixes a real, long-standing defect: the batch miss-fill never
fired. No changes needed. One pre-existing edge case in the single-key JSON
path is recorded.

## Summary of the PR

- `get_settings_cached/2` / `get_json_settings_cached/2` detected misses with
  `Map.has_key?/2`, but `Cache.get_multiple/3` returns **every** key and fills a
  miss with `Map.get(defaults, key)`. With `%{}` as defaults, a miss therefore
  looked like a cached `nil`, and the database was never asked. The fix passes a
  per-key sentinel as the cache default and treats a key as a miss when it comes
  back as that sentinel.
- `fill_missing_settings/1` no longer caches a restricted key that failed to
  decrypt. This mirrors the boot warmer's `undecryptable_at_boot?/1`, and the
  warmer also drops a restricted `nil` after decrypting.
- `fill_missing_json_settings/1` uses `Map.fetch` instead of `||`, so a row that
  exists with no JSON value is cached as `nil` instead of as not-found.

## Verified

- **The premise is true.** `Cache.handle_call({:get_multiple, ...})`
  (`cache.ex:452`) calls `Map.put(acc, key, Map.get(defaults, key))` on both the
  expired and the absent branches. The `:noproc`/timeout fallbacks return
  `defaults` verbatim, so the `:error` clause really is unreachable.
- **`restricted_decrypt_failure?/2` cannot misfire on a real value.**
  `update_setting/2` stores `nil` as `""`, and `decrypt_if_restricted/2` returns
  `nil` only in its `{:error, _}` branch. A found restricted key mapped to `nil`
  is therefore always a decrypt failure.
- **Behaviour change for sibling packages.** `phoenix_kit_web_analytics`
  (`Config`, `@hot_keys`) and `phoenix_kit_publishing` (three LiveViews) call
  `get_settings_cached/2`. On a cold or expired cache they now get database
  values instead of `nil`. This is the intended fix. It also means a stopped
  cache process costs one batch query per call, same as the single-key path.
- **`update_mode`** still short-circuits both fills (`query_settings_or_error/1`,
  `fill_missing_json_settings/1`).

## NITPICK — the single-key JSON path disagrees with the batch path (pre-existing, not changed)

`query_and_cache_json_setting/1` has no clause for a row whose `value` is `""`
and whose `value_json` is `nil`. The `CaseClauseError` is rescued, so every read
logs `Failed to query JSON setting` and nothing is cached. A row with a
non-empty string value caches `nil` but returns `nil || default` on the miss and
`nil` on the next hit. The batch path now answers `nil` consistently. The
single-key path predates this PR and no core caller hits it, so it is left for
its own change. The shared-cache shape race between the string and JSON read
paths is already documented in the PR's own comment block.
