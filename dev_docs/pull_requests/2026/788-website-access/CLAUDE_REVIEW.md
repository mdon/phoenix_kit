# PR #788 — Website access: one settings page, switchable features, presets (V187)

Author: mdon · Merged: 2026-09-07 (`027156f7`, squashed from `9999b35c`, `08ba1096`, `ee48b351`)
Reviewed by: Claude (5 parallel scoped passes: gate/attempts, redirect/notice/robots,
plug+auth+IP wiring, LiveView settings page, maintenance refactor + V187 migration +
settings cache-warmer fix)

Scope: 60 files, +14431/-5000. New `PhoenixKit.WebsiteAccess` feature bundle (password
gate, redirect-to-production, visitor notice, maintenance-as-a-feature, crawler
noindex, allowed addresses), one settings page with presets, V187 migration
(`phoenix_kit_access_attempts`), and a settings-cache-warmer decryption fix found
while deploying.

## Findings

### BUG - HIGH — flaky/deterministically-failing test
**File:** `test/phoenix_kit/website_access_test.exs:46` (test: "the closed page's switch
follows the real state, so a scheduled window can be opened by hand")

The test asserted `:ok = Maintenance.update_schedule(DateTime.add(DateTime.utc_now(), -60,
:second), nil)`. `validate_not_past/2` rejects when `DateTime.diff(dt, DateTime.utc_now()) <
-60`. Wall-clock time always advances between computing the `-60s` input and the check
running, so the measured diff is always slightly more negative than `-60` — the assertion
failed on every run (`{:error, :start_in_past}`), reproduced 4/4 locally against
`beamlab_test`. CI is manual-only in this repo and this suite wasn't run post-merge, so it
shipped broken.

**Fix applied:** changed the input to `-10` seconds, comfortably clear of the 60s tolerance
boundary. Verified green.

### IMPROVEMENT - MEDIUM — bespoke local-path regex instead of the vetted guard
**File:** `lib/phoenix_kit_web/controllers/website_access_controller.ex` (`return_to/1`)

The gate's `?to=` redirect-target validation reimplemented local-path checking with its own
regex (`~r{\A/(?![/\\])[^\s\\\x00-\x1f]*\z}`) instead of calling
`PhoenixKit.Utils.Routes.local_path?/1`, which CLAUDE.md documents as the one supported
guard for a client-influenced redirect target — precisely so every such check moves
together. The bespoke regex was slightly weaker (didn't exclude DEL, 0x7F) and could drift
further from the vetted guard on a future edit to either side.

**Fix applied:** `return_to/1` now calls `Routes.local_path?/1` as the base check, with the
gate-specific rules (no fragment, no `.`/`..` segment, not the gate's own path) layered on
top, plus an explicit space-rejection kept for parity with the existing test suite (`"/x
y"` must still be rejected; `local_path?/1` itself only blocks ASCII control chars + DEL,
not a bare space). All 15 existing controller tests still pass.

### IMPROVEMENT - MEDIUM — `mount/3` runs real queries unconditionally
**File:** `lib/phoenix_kit_web/live/settings/website_access.ex:41-66` (`mount/3` →
`assign_state/1`)

`mount/3` unconditionally calls `assign_state/1`, which issues `Gate.list_attempts(limit:
200)`, `Gate.attempt_counts()` (a `GROUP BY`), and uncached `Settings.get_setting/2` reads.
Per the Iron Law, `mount/3` runs twice (disconnected HTTP render + connected WebSocket
mount) with no `connected?/1` guard around the query-backed portion and no
`handle_params/3` data loading (it's a no-op).

**Deliberately not fixed here:** the identical pattern (settings loaded unconditionally in
`mount/3`, no `connected?/1` guard) already exists in this repo's own
`lib/phoenix_kit_web/live/settings/organization.ex`. Fixing it only on this page would
diverge from an established, if imperfect, convention for admin settings LiveViews without
addressing the same issue elsewhere — and the traffic profile (admin-only settings page) makes
the double-query cost negligible. Worth a repo-wide follow-up, not a one-off patch here.

### IMPROVEMENT - MEDIUM — missing coverage for the same-minute schedule bypass
**File:** `lib/modules/maintenance/maintenance.ex:281-297` (`check_schedule/2`,
`same_minute?/2`)

`check_schedule/2` was added specifically so re-saving a schedule whose start already
elapsed (form re-submit, or moving just the end) doesn't spuriously fail
`validate_not_past`. No test exercised this path — existing tests only ever call
`update_schedule/2` with a first-time start.

**Fix applied:** added two tests to `test/integration/maintenance/maintenance_test.exs`
under `update_schedule/2`: re-saving the identical (now-past) start succeeds, and a
genuinely different past start is still rejected even with a stored schedule present.
Both pass.

### NITPICK — stale comment (fixed)
**File:** `lib/modules/maintenance/web/plugs/maintenance_mode.ex:159`

Comment said "the page's 5-second refresh keeps even that honest," but the meta-refresh in
this same PR was changed to `content="30"`. Updated the comment to say 30s.

### NITPICK — dead icon-mapping clause (removed)
**File:** `lib/phoenix_kit_web/components/admin_nav.ex`

`"maintenance" -> <.icon name="hero-wrench-screwdriver" />` was unreachable — no tab/module
card passes `icon: "maintenance"` anymore (grepped `lib/phoenix_kit_web/` and
`lib/modules/`, zero hits besides the clause itself and an unrelated LiveView event name).
Removed; the generic fallback icon covers it if it's ever needed again.

### NITPICK — no direct unit test for `client_address_from_socket/1` (not fixed)
**File:** `lib/phoenix_kit/utils/ip_address.ex:121-138`

No test calls this function directly; it's only exercised transitively through
`auth.ex`'s `remembered_address/2`, covered by the LiveView relock tests. Low priority —
behavior is verified, just not in isolation. Left as-is; not worth new test surface on its
own.

## Areas reviewed with no findings

- **Password gate / attempt logging** (`gate.ex`, `attempt.ex`): epoch rotation, per-address
  advisory lock around the lockout-check + write, constant-time password comparison,
  verdict classification, typed-value narrowing, pruning that respects the lockout window —
  all correct and tested (including a dedicated "parallel guesses can't slip past lockout"
  test).
- **Redirect / notice / robots** (`redirect.ex`, `notice.ex`, `crawlers.ex`): GET/HEAD-only
  enforcement, host+port loop guard (proxy-aware), byte-safe body injection, HTML-escaped
  notice text/link, `x-robots-tag` set ahead of redirect/gate/maintenance in the plug chain.
- **Plug chain + auth wiring + IP resolution** (`plugs/website_access.ex`, `users/auth.ex`,
  `utils/ip_address.ex`, `allowed_addresses.ex`, `environment.ex`,
  `phoenix_kit/website_access.ex`): single `on_mount/4` funnels every hook through the gate
  check (structurally can't be skipped by a new hook); `client_address/1` only trusts
  X-Forwarded-For/X-Real-IP when the immediate peer is loopback/private; an unknowable
  socket address fails closed (`AllowedAddresses.allowed?(nil)` → `false`); the environment
  panel has no write path; all mutations route through `Settings`/module contexts, never a
  bare `Repo` call.
- **V187 migration + `expected_schema.ex`**: bare index names on `CREATE INDEX`,
  name-based `pg_constraint`+`pg_class`+`pg_namespace` join (no bare `regclass` cast),
  `Helpers.ensure_uuid_v7_function/1` used correctly, idempotent up/down, 9 objects match
  column-for-column and index-for-index against `expected_schema.ex`.
- **Settings cache-warmer decryption fix**: the warm map genuinely skips (not
  nil-caches) a restricted key it can't decrypt yet; a decrypt-failure cache miss answers
  nil without writing it to cache, so a later read retries; exercised by
  `test/phoenix_kit/settings_test.exs`.
- **Maintenance module API**: `PhoenixKit.Modules.Maintenance` keeps its full public
  surface; `lib/modules/maintenance/settings.ex` deletion left no dangling references
  anywhere in `lib/`.

## Validation

- `PGDATABASE=beamlab_test mix test test/phoenix_kit/website_access_test.exs` — green
  (was red before the fix).
- `PGDATABASE=beamlab_test mix test test/phoenix_kit_web/controllers/website_access_controller_test.exs`
  — 15/15 green after the `local_path?/1` refactor.
- `PGDATABASE=beamlab_test mix test test/integration/maintenance/maintenance_test.exs --include integration`
  — 28/28 green, including the 2 new same-minute-bypass tests.
- Full `mix precommit` + `mix test` run next.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DVcaS4NG63JZgZTntpWbEX
