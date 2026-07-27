# PR #665 — Notification delivery channels, personal integrations, permission hardening

**Author:** mdon (Dmitri Don)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-27
**Verdict:** ⚠️ APPROVE WITH FIXES — already merged. One HIGH bug that silently
drops notifications on every upgraded host, two MEDIUM bugs, one NITPICK. All
four fixed post-merge; the remaining findings are recorded, not fixed.

---

## Summary

Three large, mostly-independent features in one PR:

1. **Notification delivery channels** — a parallel routing layer (Model B) that
   sends notifications to external destinations (Email, Telegram) alongside the
   in-app inbox, with per-type opt-in and per-type delivery cadences
   (immediate / hourly / 12h / daily / weekly).
2. **Personal (per-user) integrations** — connections gain an owner
   (`:system | :any | {type, id}`) stored in the existing JSONB, plus a second
   admin surface at `/admin/settings/integrations` gated by its own permission
   key, with the website-wide pages moved under `/website`.
3. **Permission hardening** — the `"*"` superadmin key, `Scope.admin?/1` renamed
   to `can_access_admin_area?/1`, uniform disabled-module enforcement (Owner no
   longer bypasses), a role-row lock shared by every mutation path, and an audit
   trail for grant/revoke/sync.

Plus V159 (publishing categories + post view counters), which is unrelated to
the above and rides along.

The engineering quality is high. The owner-scoping work in particular is careful
in the ways that matter: `resolve_uuid/2` is a genuine single chokepoint,
`owner_uuid` is write-once and dropped from incoming attrs, `add_connection/4`
enforces the provider's declared scope at row birth rather than only in the
picker, and `owner_uuid` is correctly kept out of `@sensitive_fields` so the
`->>` filter works. The permission work's `holds_all_enabled_permissions?/1`
baseline (enabled keys *minus* the opt-in ones) is the right shape and is
reasoned about explicitly in the code.

## Files changed

82 files, +6595/−778. The review focused on the new subsystems
(`lib/phoenix_kit/notifications/`, `lib/phoenix_kit/integrations/`,
`lib/phoenix_kit/users/permissions.ex` + `auth/scope.ex`,
`lib/phoenix_kit_web/users/auth.ex`, `lib/phoenix_kit/install/oban_config.ex`,
`lib/phoenix_kit/migrations/postgres/v159.ex`) and their call sites.

---

## Findings

### BUG - HIGH — digest cron entries never reach existing hosts, and a digest cadence then drops notifications entirely

`lib/phoenix_kit/install/oban_config.ex`

`ensure_cron_plugin/2` short-circuits at "Case 2: Cron plugin exists with new
worker — already configured" the moment `ProcessScheduledJobsWorker` is in the
crontab. The PR added the four `DigestWorker` entries to the **generated
template** (`config/config.exs` and the two install templates) and added
`ensure_notifications_queue/2` for the queue — but nothing backfills the cron
entries into an existing host's `config/config.exs`. So `mix phoenix_kit.update`
leaves every already-installed app with a digest-less crontab, forever.

That is not merely "digests don't fire". `DigestWorker` is enqueued *only* by
those cron entries (verified: no other call site in `lib/` or `config/`), and
the creation path already suppresses the per-event inbox row once a type is on a
non-immediate cadence:

```elixir
# notifications.ex — route_activity/1
{Prefs.user_wants?(user, entry.action) and inapp_immediate?(user, entry.action), ...}
```

So on an upgraded host a user who picks "Daily" for a type in the new
Aggregation popup gets **no per-event row and no summary** — the notifications
are silently and permanently lost, in-app and external alike. The feature looks
wired (the queue is added, the UI offers the cadences) which makes the failure
harder to spot.

**Fixed.** Added `ObanConfig.ensure_digest_cron_entries/2`, wired into
`update_existing_oban_config/3` immediately after `ensure_cron_plugin/2` (which
guarantees a `crontab:` block exists). It checks each cadence independently, so
a partially-updated crontab converges, and it anchors the crontab block's
closing `]` to the `crontab:` keyword's own indentation — the same
backreference guard `add_cron_plugin_to_plugins/2` uses, because a lazy `.*?`
to the first `]` can stop inside an entry's own nested list. Made public (like
`ensure_lifeline_plugin/2`) so it is unit-testable against plain strings; six
tests added in `test/phoenix_kit/install/oban_config_test.exs`, including an
idempotency test and a drift test asserting the scheduled cadence set equals
`ChannelConfig.cadences/0` minus `"immediate"`.

**Pre-existing, not fixed:** the same gap applies to
`PhoenixKit.Notifications.PruneWorker` (added in an earlier release, also only
in the template). Out of this PR's scope, but worth folding into the same helper
later.

### BUG - MEDIUM — notification settings LV persists unvalidated channel and type keys from params

`lib/phoenix_kit_web/live/notifications/settings.ex`

`save_channel_types/2` and `save_cadences/2` both iterated the raw params map
and used its keys directly as storage keys:

```elixir
Enum.reduce_while(channel_params, {:ok, user}, fn {channel_key, cfg}, {:ok, acc_user} ->
  ...
  ChannelConfig.update(acc_user, channel_key, fn config -> ... end)
```

Form params name their own keys, so on a crafted `phx-submit` both the channel
key and the inner type/cadence keys are attacker-controlled. A hand-rolled event
writes arbitrary `custom_fields["notification_channel:<anything>"]` blobs — with
arbitrary nested `types`/`cadences` entries — into the user's JSONB, permanently
and unboundedly. Note the contrast with the sibling `save_in_app/3` in the same
module, which correctly builds its map from `Types.all_pref_keys()` rather than
from params.

Impact is bounded (a user can only write to their own row, and the downstream
readers — `Routing.targets_for_type/2`, `DigestWorker.digest_config/5` — resolve
unknown keys to `nil` and skip them), so this is data hygiene and unbounded
row growth rather than privilege escalation. But it is unvalidated persistence
into a column several subsystems read.

**Fixed.** Both paths now `Map.take/2` against the live registries before
writing: `Channels.keys()` for channel configs, `["inapp" | Channels.keys()]`
for cadence modes (mirroring `aggregate_body/1`'s `@modes`), and
`Types.all_pref_keys()` for the type keys inside each.

### BUG - MEDIUM — `Channels` registry drops module-contributed channels that aren't loaded yet

`lib/phoenix_kit/notifications/channels.ex`

`external_channels/0` guarded with a bare `function_exported?(mod,
:notification_channels, 0)`. `function_exported?/3` answers `false` for a module
that simply hasn't been loaded — the norm under a release's lazy module loading.
So a feature module's channel would silently fail to register, and the only
symptom is a missing column in the settings matrix.

This is the "two parallel registries drifted" case: the sibling
`Types.external_types/0`, written in the same PR for the same merge pattern,
gets it right (`Code.ensure_loaded?(mod) and function_exported?(...)`).

**Fixed.** `Channels.external_channels/0` now mirrors `Types`.

### NITPICK — Telegram broadcast reports success when every send fails permanently

`lib/phoenix_kit/notifications/channels/telegram.ex`

The multi-target arm of `deliver_to/2` returns `:ok` in the `true ->` branch,
which is reached when no send succeeded *and* none was transient — i.e. every
chat failed permanently. Returning `:ok` is the right call (one blocked
subscriber must not soft-disable a working broadcast), but it was silent: a
revoked bot token or a bot kicked from every chat looks exactly like a
successful delivery in the logs, forever.

**Fixed.** Added a `Logger.warning` naming the target count and the failed
results in that branch. Behaviour (`:ok`) is unchanged.

---

## Recorded, not fixed

- **Cadence controls are inert for standalone-only types.** `do_create_standalone/1`
  routes through `Routing.targets_for_type/2`, which never consults the cadence,
  and `DigestWorker` counts only `Activity.Entry` rows. This is documented
  ("Only activity-driven types aggregate — standalone notifications are always
  immediate"), but the Aggregation popup still renders Hourly/Daily/Weekly for
  such a type — `"security"` being the shipped example, since
  `user.new_login_detected` is self-actor (`actor_uuid == target_uuid`) and so
  reaches the inbox only via `LoginAlerts.notify_in_app/2`'s standalone call.
  Choosing a cadence there changes nothing. Worth either hiding the control for
  standalone-only types or noting it in the popup.

- **A base type's master switch is in-app-only.** `Routing.targets_for_type/2`
  checks `config["types"][leaf_key]` alone, so turning "Posts" off mutes the
  inbox but not Telegram/Email. That follows from Model B's independent
  destinations and matches the matrix layout (the master toggle sits in the
  In-app column), so it is consistent — just non-obvious.

- **`DigestWorker` is O(users × types) queries per run.** `users_with_cadence/1`
  loads every user carrying any `notification_channel:*` key and filters in
  Elixir, then `count_events/3` issues one aggregate per (user, type). Fine at
  current scale; a candidate for a single grouped query if channel adoption
  grows.

- **DB queries in `mount/3`.** `Live.Notifications.Settings.mount/3` calls
  `assign_channels/1` → `Telegram.configured?/2` → `Integrations.list_connections/2`,
  so the query runs twice per page load (HTTP render + WebSocket connect). Same
  for `Live.Settings.mount/3`'s `list_all_settings/0`. Consistent with the rest
  of the codebase rather than introduced here, so left alone — but it is the
  LiveView Iron Law and the new page is a fresh instance of it.

- **`owner_of/1` and `owner_where/2` disagree on a malformed `owner_uuid`.** A
  row whose `owner_uuid` is a non-uuid string reads as `:system` via
  `owner_of/1` (so `resolve_uuid(uuid, :system)` will mutate it) but is excluded
  by `owner_where(:system)`'s `->>'owner_uuid' IS NULL` filter (so it never
  appears in a listing). Unreachable through the public API — `put_owner/2`
  raises on a non-uuid id — so this is defence-in-depth asymmetry only.

---

## Verification performed

- **Cross-checked the `Types` action whitelist against real emitters.** `rg`'d
  every `Activity.log` call in `lib/` that sets `target_uuid` and matched the
  action strings against `core_types/0`. Unclaimed: `user.qr_login_approved`,
  `user.created`, `user.deleted`, `session.account_added`, `session.switched`.
  All are benign — `key_for_action/1` returning `nil` is fail-open for the
  in-app inbox and fail-closed for external routing, which is the documented
  and correct contract for actions nobody has opted a channel into.

- **Traced the `"security"` type end to end** (the new type in this PR) rather
  than assuming its trigger fires. `user.new_login_detected` is logged with
  `actor_uuid == target_uuid`, so `maybe_create_from_activity/1` skips it at the
  self-action guard; the notification actually arrives through
  `LoginAlerts.notify_in_app/2` → `Notifications.create/1` with `type: "security"`,
  which does route externally via `standalone_targets/2`. Coherent — but it is
  the reason the cadence control is inert for that type (above).

- **Confirmed `DigestWorker` has no enqueue site other than cron** (`rg
  DigestWorker lib/ config/`), which is what makes the missing cron entries a
  silent data-loss bug rather than a degradation.

- **Oban args serialization.** The cron entries pass `args: %{cadence: "hourly"}`
  with an atom key; `perform/1` matches `%{"cadence" => cadence}`. Correct —
  JSON round-tripping turns the atom into a string, and the worker honours that.

- **Owner threading in the personal LVs.** Every `Integrations.*` call in
  `my_integration_form.ex` / `my_integrations.ex` passes an explicit `owner:`
  sourced from the request scope, never from params. The two that don't
  (`validate_credentials/2`) are stateless and take no uuid.

- **`resolve_uuid/2`'s `:system` default on the auto-status paths.**
  `record_refresh_failure/2` and `maybe_record_recovery/1` use the default
  `:system` scope; both are reached only from `refresh_access_token/2`, and
  OAuth2 providers are `[:system]`-only per `Providers.scopes_of/1`, so the
  default is right rather than an oversight.

- **`@deprecated Scope.admin?/1` has no remaining internal call site** (grepped
  `lib/` and `test/`), so `--warnings-as-errors` stays green — including
  `admin_edit_helper.ex`, whose local `admin?/1` now delegates to
  `can_access_admin_area?/1`.

- **Owner's `holds_all_enabled_permissions?/1` path.** `Scope.for_user/1` gives
  Owner `MapSet.new(Permissions.all_module_keys())`, which now includes `"*"`,
  so `superadmin?/1` short-circuits true. The `enforce_admin_view_permission/2`
  fallback swap from `system_role?` to `holds_all_enabled_permissions?` does not
  lock out Owner or a default Admin.

- **Route ordering.** `/admin/settings/integrations/website*` is declared before
  `/admin/settings/integrations/:uuid`, and `/new` before `/:uuid`, so no static
  segment is captured as a uuid.

- **`match: {:regex, ~r{^/admin/settings/integrations(?!/website)}}`** on the
  "My Integrations" subtab is evaluated against `Tab.normalize_path/1` output,
  which strips both the url prefix and the locale prefix — so the `^`-anchor
  holds on a prefixed/localised install.

- **V159 against the prefix rules in AGENTS.md.** Index names bare on `CREATE`,
  tables schema-qualified, `uuid_generate_v7()` qualified with the prefix,
  `COMMENT ON TABLE` version stamp correct, `@current_version` bumped to 159.
  Clean.

## Gate

`mix precommit` (format + `compile --warnings-as-errors` + `credo --strict` +
dialyzer) — see the release commit. Integration tests were not run: per the
project's testing stance the gate, not `mix test`, is the bar in this repo.

---

## Second-pass review (Grok) — 2026-07-27

**Scope:** Meta-review of the findings and post-merge fixes above (commit
`be0505e5`, release 1.7.214), not a full re-read of the 82-file PR. Verified
each claimed fix against the current tree and re-ran the new unit tests.

**Verdict on this review:** ✅ Findings and fixes hold. No release-blocking
residuals. Severity calibration is right; the HIGH path is real silent data
loss, not theoretical.

### Confirmed

- **BUG HIGH (digest cron backfill)** — Re-traced end to end. `ensure_cron_plugin/2`
  Case 2 short-circuits once `ProcessScheduledJobsWorker` is present; digests
  lived only in the install template. Creation path skips the per-event inbox
  row when cadence ≠ `"immediate"` (`inapp_immediate?/2`), and external
  channels only enqueue when `ChannelConfig.immediate?/2` — so without
  `DigestWorker` on cron, Daily/Weekly is silent loss for **in-app and
  external alike**. Fix shape is solid: public helper after cron is guaranteed,
  per-cadence converge, indent-anchored `]` (same bug class as Lifeline), drift
  test vs `ChannelConfig.cadences() − "immediate"`. Insertion produces valid
  Elixir (`Code.string_to_quoted` OK). All six new
  `ensure_digest_cron_entries/2` tests pass under `mix test
  test/phoenix_kit/install/oban_config_test.exs`.
- **BUG MEDIUM (unvalidated form keys)** — Confirmed; contrast with
  `save_in_app/3` was the right catch. `Map.take` against `Channels.keys()` /
  `Types.all_pref_keys()` / `["inapp" | Channels.keys()]` plus existing
  `sanitize_cadence/1` is the right shape. Non-map leaf values degrade to `{}`
  via the `is_map` guards.
- **BUG MEDIUM (`function_exported?` without `ensure_loaded?`)** — Confirmed
  parallel-registry drift vs `Types.external_types/0`.
- **NITPICK (Telegram all-permanent-fail → silent `:ok`)** — Fair; logging
  without changing `:ok` is the right multi-target tradeoff.
- **Recorded items** — Standalone-only cadence UI, Model B master-toggle
  semantics, O(users×types) digests, mount double-query, `owner_of` /
  `owner_where` asymmetry, PruneWorker backfill gap — all real, none blocking.
  Leaving them unfixed was good scope discipline.
- **Release timing** — Features and fixes landed in the **same** Hex version
  (1.7.214). No broken digest-cadence release went out to hex users. Anyone who
  ran git `main` between the #665 merge and `be0505e5` still needs
  `mix phoenix_kit.update` after pulling 1.7.214.

### Additional findings (not fixed here)

- **NITPICK — settings param filter has no automated test.** Only the Oban
  installer path got tests. The LV helpers are private; extracting
  `known_channel_params` / `known_type_params` (or a pure unit around them)
  would lock the MEDIUM fix. Acceptable given no LiveView harness for that page.
- **IMPROVEMENT - LOW (follow-up) — PruneWorker still not backfilled.** Same
  class of bug as digests (template-only + `ensure_cron_plugin/2` short-circuit).
  Correctly filed as pre-existing; worth folding into the same helper family
  later so prune + digests converge on `mix phoenix_kit.update`.
- **IMPROVEMENT - LOW (follow-up) — inert cadence UI for standalone-only
  types** remains the most user-visible residual on the new settings page.
  Hide or label the control for types that never hit `DigestWorker` (e.g.
  `"security"` via standalone).

### Gate (second pass)

- `mix test test/phoenix_kit/install/oban_config_test.exs` — 25 tests, 0 failures
  (includes the six new digest-cron cases).
- Hex + tag: `1.7.214` present on hex.pm and as `v1.7.214`.
