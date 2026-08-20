# Claude Review — PR #741 "Stop leaking OAuth/AWS secret values into the General and Users settings pages"

**Merge commit:** d2bf4a4df1a16837e817f0bee7f97778ee0cfc35
**Author:** timujinne (fix/settings-display-secret-leak)
**Files:** `lib/phoenix_kit/settings/settings.ex`, `lib/phoenix_kit_web/live/settings.ex`, `lib/phoenix_kit_web/live/settings/users.ex`, `test/phoenix_kit/settings_test.exs`

## Summary of the change

Before this PR, the General (`Live.Settings`) and Users (`Live.Settings.Users`)
LiveViews both called `Settings.list_all_settings/0` unconditionally in
`mount/3`, so the real values of the 5 OAuth/AWS credential settings
(`oauth_google_client_secret`, `oauth_github_client_secret`,
`oauth_facebook_app_secret`, `aws_access_key_id`, `aws_secret_access_key`)
sat in process/socket state on two pages that never render them — only the
Authorization page's template does. The core's only prior notion of
"sensitive" was `module == "integrations"`, which OAuth login credentials
never belonged to.

The fix adds `Settings.list_public_settings/0`, backed by an explicit
`@public_setting_keys` allow list (not a blacklist/redaction of
`list_all_settings/0`), and switches both pages to it. A new
`settings_test.exs` locks in a partition invariant: every key in
`get_defaults/0` must be classified on exactly one of
`@public_setting_keys` / `@restricted_setting_keys`, so a new setting that
nobody classifies fails the test instead of silently landing wherever
`list_public_settings/0` is read — including two tests that deliberately
corrupt the lists to prove the invariant isn't vacuous.

## Review

- **Partition is exhaustive and correct.** Diffed `@public_setting_keys` +
  `@restricted_setting_keys` (62 keys total) against every key literal in
  `Settings.get_defaults/0` — exact match, no gaps, no overlap. Confirmed
  the `oauth_*_client_secret`/`aws_*` keys are the only ones referenced in
  `authorization.html.heex`, and neither `settings.html.heex` nor
  `users.html.heex` references any restricted key — the allow list matches
  what the templates actually need, not just what the PR claims.
- **`Map.take` after `Map.merge` is load-bearing, not redundant.**
  `get_defaults()["aws_access_key_id"]` calls `AWS.access_key_id()`, which
  can return the **host's real configured AWS key**, not a placeholder —
  so `Map.merge(defaults, current_settings)` alone would reintroduce a live
  secret into `merged_settings` even though `list_public_settings/0`
  correctly excluded it from `current_settings`. Both LiveViews re-filter
  with `Map.take(Settings.public_setting_keys())` after the merge, which
  is exactly the right guard — verified it's necessary, not defensive
  clutter. (The inline comment calling the defaults "harmless placeholder
  values" undersells this — worth a follow-up comment fix, not blocking.)
- **`get_setting_options/0`** (also assigned into both sockets) only holds
  dropdown option lists (roles, timezones, date formats), no setting
  values — confirmed it carries no secret exposure.

## Findings

### BUG - HIGH: `reset_to_defaults` on the General page still overwrote the restricted keys

`Live.Settings.handle_event("reset_to_defaults", ...)` called
`Settings.update_settings(Settings.get_defaults())` with the **unfiltered**
defaults map — all 62 keys, including the 5 restricted ones. `update_settings/1`
→ `update_all_settings_from_changeset/1` writes every key present in
`changeset.params`, so clicking "Reset" on the General page silently
overwrote the DB-stored OAuth client secrets and AWS credentials (to `""`,
or — for `aws_access_key_id`/`aws_secret_access_key` — to whatever
`PhoenixKit.Config.AWS` currently resolves to via env/host config).

This directly contradicts the PR's own premise, stated in its own comment
on this file: "this page never renders the OAuth login secrets or AWS keys
... so it has no reason to hold their real values ... at all." The mount
fix scoped what the page *reads*; this handler was the one place it still
*wrote* the restricted keys. The confirm dialog
(`settings.html.heex:602-606`) only promises "Your title, logo, formats and
feature toggles will be replaced" — it never mentions OAuth or AWS
credentials, so an admin clicking Reset has no warning that their live
OAuth login config or SES/SQS integration would be wiped.

**Fix applied:** `lib/phoenix_kit_web/live/settings.ex` — filter
`Settings.get_defaults()` through `Map.take(Settings.public_setting_keys())`
before passing it to `update_settings/1`, matching the same guard already
used for the mount-time merge.

**Test added:** `test/integration/phoenix_kit_web/live/settings/settings_reset_test.exs` —
seeds a live OAuth secret + AWS secret + a non-default `project_title`,
clicks Reset via the LiveView, and asserts the secrets are untouched while
`project_title` reverts to its default. Confirmed this test fails against
the pre-fix code (`""` instead of the seeded secret) and passes after.

The Users page (`Live.Settings.Users`) has no `reset_to_defaults` handler,
so it wasn't exposed to this bug.

## Verdict

The core allow-list mechanism is sound and the partition test meaningfully
guards future settings additions. One real gap survived scope-limiting the
page: the reset path. Fixed and covered by a regression test; gate run
clean (see commit).
