# PR #649: V152: deliveries addressability CHECK + friendly incomplete-credentials flash

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, no changes needed
**Date**: 2026-07-19

## Goal

Two independent, small fixes:

1. Adds `phoenix_kit_newsletters_deliveries_recipient_check` — `CHECK
   (user_uuid IS NOT NULL OR recipient_email IS NOT NULL)` — to V152 (still
   the unreleased accumulator migration, no version bump). Backstops the
   crm_list delivery source added earlier in the same migration, which
   dropped `user_uuid`'s `NOT NULL` without adding anything in its place.
2. `email_sending.ex`'s "Send test email" handler gains a dedicated clause
   for `{:error, {:incomplete_credentials, missing_fields}}` (the error
   shape introduced in 1.7.203's `Mailer.swoosh_config_for/1` fail-closed
   fix) instead of falling through to the generic `inspect(reason)` flash.

## Verified correct (no action needed)

- The guarded `ADD CONSTRAINT` follows the established idiom (Postgres has
  no `ADD CONSTRAINT IF NOT EXISTS`; guard via an existence check in a `DO
  $$` block) and is **schema-anchored**:
  `information_schema.table_constraints WHERE table_schema =
  '#{escaped_prefix}' AND table_name = 'phoenix_kit_newsletters_deliveries'
  AND constraint_name = '...'`. This is exactly the anchor CLAUDE.md calls
  out as required (an unanchored `information_schema` check would see
  `public`'s constraint on a prefixed install sharing a database with a
  public install, and silently skip creating the prefixed one).
- `down_broadcast_crm_source/3` drops the constraint before the section's
  existing `DROP INDEX`, and doesn't touch the deliberate "NOT NULLs are
  not restored" behavior documented earlier in the same moduledoc section —
  consistent with that existing rollback design (lossy on purpose).
- Test coverage exercises the constraint at the SQL layer (raw
  `Repo.query/2`, not through Ecto's changeset validation) so it actually
  proves the DB-level guard works independently of the Elixir-side check:
  neither-set is rejected with `check_violation`, email-only accepted (the
  new crm_list path), user-only accepted (the pre-existing newsletters_list
  path, regression-guarded).
- `email_sending.ex`: the new clause is ordered before the generic
  `{:error, reason}` fallback, so it doesn't change behavior for any other
  error shape — Elixir's `case` matches top to bottom, and
  `{:incomplete_credentials, _}` only ever comes from
  `Mailer.swoosh_config_for/1`. `Enum.map_join(missing_fields, ", ",
  &to_string/1)` handles the field-name atoms cleanly (`[:host, :aws_region]`
  → `"host, aws_region"`).
- No version bump needed for the V152 change — matches the project's "one
  open migration" rule for the in-progress restructuring accumulator; V153
  (already landed via PR #648, merged just before this one) is unaffected
  since it's a separate table.

## Noted, not fixed

Nothing found worth flagging — this PR is small, well-tested, and follows
existing conventions exactly.
