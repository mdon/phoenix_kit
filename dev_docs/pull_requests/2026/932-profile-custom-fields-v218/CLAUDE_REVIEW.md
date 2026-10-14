# PR #932 — Profile form: user-editable custom fields only, never the email; V218 sync rate-limit default 600

**Author:** mdon · **Reviewer:** Claude · **Verdict:** sound; one residual limitation recorded, no code change needed

Scope: `User.profile_changeset/3` + `CustomFields.cast_user_input/2`, `UserSettings` profile events,
V218 (`rate_limit_requests_per_minute` default 60 → 600), docs.

## Checked and fine

- The admin edit page (`user_form.ex`) deletes `custom_fields` from `profile_params` and writes them through its own
  `update_custom_fields`, so narrowing `profile_changeset` does not break admin saves. Its two
  `profile_changeset` calls (validate / reload) only build display changesets.
- `cast_user_input/2`: internal keys, undefined keys, structured stored values, unchanged values, over-length and
  off-list `select` values are all dropped or refused as documented; atom and string keys both handled.
- `Map.delete(user_params, "email")` is applied to both `validate_profile` and `update_profile`.
- V218 is idempotent, prefix-safe (`V203.prefix_str/1`), `down/1` documented as default-only; `expected_schema`
  revision `{218, …}` appended and `@chain_hash` restamped. `v218_test`, `profile_custom_fields_authority_test` pass
  against a real DB.

## Findings

### IMPROVEMENT - MEDIUM — accepted fields are merged over a possibly stale struct (not fixed)

`cast_user_custom_fields/2` builds `Map.merge(changeset.data.custom_fields, accepted)` and `Repo.update` writes the
**whole** JSONB column. `changeset.data` is the `user` held in the LiveComponent's assigns, so a system key written
since the page loaded (avatar file, notification routing, an invite stamp — via `merge_user_custom_fields/3`) is
restored to its old value when the holder saves one editable field. The new moduledoc/AGENTS.md line ("every other
stored key keeps its value") holds only for a fresh struct.

Not a regression: the removed `merge_custom_fields_for_save/3` had the same window. Not fixed here because the
correct fix is an atomic `custom_fields || accepted` in `Auth.update_user_profile/2` (like
`merge_user_custom_fields/3`), which also reshapes what `Activity.log_user_change/3` diffs. Worth a dedicated
change; until then treat the guarantee as "unknown keys are never *written by the form*", not "never overwritten".

### NITPICK — `profile_params/1` drops only the string key `"email"`

Fine for form params (always string-keyed); a future caller passing atom keys would bypass it. The changeset still
casts `email`, so the guard lives in the component rather than the changeset — acceptable, noted.
