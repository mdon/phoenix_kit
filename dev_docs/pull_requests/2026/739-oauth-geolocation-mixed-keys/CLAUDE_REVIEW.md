# Claude Review — PR #739 "Fix Ecto.CastError on OAuth registration with geolocation tracking enabled"

**Merge commit:** e27b2ff742b20b24d69c3a126ed99875b0a4972f
**Author:** timujinne (fix/oauth-geolocation-mixed-keys)
**Files:** `lib/phoenix_kit/users/auth.ex`, `test/integration/users/oauth_email_verification_test.exs`

## Summary of the change

`Auth.register_user_with_geolocation/2` did `Map.put(attrs, "registration_ip",
ip)` — a string key — on top of whatever `attrs` it was handed. The OAuth
registration path (`OAuth.register_oauth_user/3` →
`do_register_oauth_user/3`) builds `attrs` atom-keyed, so with
`track_geolocation: true` and a real client IP the merge produced a
mixed atom/string-keyed map, which `Ecto.Changeset.cast/3` rejects with
`Ecto.CastError`. Fix: `stringify_keys/1` normalizes `attrs` to all-string
keys before any merge.

## Review

- **Trigger verified against the real call path**, not just the PR's claim:
  `lib/phoenix_kit/users/oauth.ex` confirms `do_register_oauth_user/3` calls
  `Auth.register_user_with_geolocation(attrs, ip_address)` exactly when
  `track_geolocation && ip_address` are both truthy — i.e. this is the live
  production path whenever a host enables geolocation tracking, not a
  hypothetical.
- **Scope of the fix is correct and not over-broad:** the sibling clause
  `register_user_with_geolocation(attrs, _invalid_ip)` forwards `attrs`
  unmodified to `register_user/2` without merging any string-keyed field into
  it, so it never produces a mixed-key map — no `stringify_keys` call needed
  there, and none was added. `register_user/2` itself only ever *reads*
  `attrs["email"] || attrs[:email]` — it never merges keys into `attrs` either,
  so it's unaffected by the same class of bug.
  ​
- **Test:** `oauth_email_verification_test.exs` reproduces the exact mixed-key
  merge via `OAuth.find_or_create_user/3` with `track_geolocation: true` and a
  real IP (`"127.0.0.1"`, which short-circuits `Geolocation.lookup_location/1`
  before any network call — keeps the test network-free while still exercising
  the crashing code path). Confirmed this test fails against the pre-fix code
  (the removed `stringify_keys/1` call) and passes after.

## Findings

None. The fix is minimal, correctly scoped to the actual defect, and backed
by a test that pins the real production trigger.

## Verdict

Clean. Release-safe as-is.
