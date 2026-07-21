# PR #657 — Atomic custom_fields merge/delete: close the concurrent lost-update race

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-21
**Verdict:** ✅ APPROVE with one fix applied post-merge — see below.

---

## Summary

Adds `PhoenixKit.Users.Auth.merge_user_custom_fields/3`, which merges keys
into a user's `custom_fields` JSONB column at the database level
(`custom_fields || additions` inside the `UPDATE` itself, via
`Ecto.Query`'s `update:`/`select:` + `Repo.update_all/2`) instead of the
historical read-modify-write pattern (`Map.merge` in Elixir, then replace
the whole map via `update_user_custom_fields/3`). That read-modify-write
pattern has a real lost-update race: two callers merging *different* keys
concurrently can each read the same pre-update snapshot, and whichever
write commits second silently overwrites the whole column, dropping the
first writer's key with no error.

`delete_user_custom_field/3` gets the same treatment
(`custom_fields - key` at the database level). `set_user_custom_field/3`
now delegates to `merge_user_custom_fields/3`.
`update_user_locale_preference/2` (the language-switcher hook — exactly
the kind of caller that used to race against, say, a newsletters opt-out
merging a different key) now routes through the atomic primitives instead
of the old whole-map replace. `PhoenixKit.RepoHelper.update_all/3` is
added as the missing delegate this needed (the dynamic-repo module didn't
expose `update_all` before).

## Files Changed (3)

| File | Change |
|---|---|
| `lib/phoenix_kit/repo_helper.ex` | +7 — `update_all/3` delegate |
| `lib/phoenix_kit/users/auth.ex` | +133/−19 — `merge_user_custom_fields/3`, atomic `delete_user_custom_field/3`, `set_user_custom_field/3` + `update_user_locale_preference/2` rerouted |
| `test/integration/users/profile_test.exs` | +142 — new suite |

## Bug found and fixed

**BUG - MEDIUM: neither atomic path bumped `updated_at`.**
`merge_user_custom_fields/3` and `delete_user_custom_field/3` build their
`Ecto.Query` `update:` clause with only `custom_fields:` in the `set:`
list. `Repo.update_all/2` is a raw bulk `UPDATE` — unlike
`Repo.update/2` on a changeset, it does **not** invoke the schema's
`timestamps/1` autogeneration, so `updated_at` was left untouched by
every call through either function. This is a real regression from the
pre-PR path: the old `update_user_custom_fields/3` (still used for
whole-map replacement) goes through `custom_fields_changeset/2` +
`Repo.update/2`, which *does* auto-bump `updated_at`. It's also
inconsistent with this codebase's own `update_all` convention elsewhere
(`lib/modules/storage/storage.ex`'s `trash_folder`/`restore_folder`
explicitly include `updated_at: now` in every `update_all` `set:` list
for exactly this reason).

Confirmed by reading `User`'s schema (`timestamps(type: :utc_datetime)`,
column nullable with default `%{}`, no DB trigger backs it — Ecto's
autogeneration is the only thing that ever sets it) and by checking the
new test suite: no test asserted on `updated_at`, so nothing caught it.

**Fix applied:** both `set:` clauses now also include
`updated_at: ^UtilsDate.utc_now()` (the project's existing
`DateTime.utc_now() |> DateTime.truncate(:second)` helper, already
aliased in this file, matching the column's `:utc_datetime` — non-usec —
precision). Added a test to each `describe` block
(`"bumps updated_at, same as update_user_custom_fields/3 would"`) that
pins the user's `updated_at` to a fixed hour-old timestamp via a direct
`update_all` before calling the function under test, then asserts the
returned struct's `updated_at` is strictly newer — deterministic
regardless of test wall-clock speed or the column's second-level
precision (a naive "assert changed since `DateTime.utc_now()` captured
right before the call" would be flaky at that granularity).

## Other things checked, no issue found

- **`RepoHelper.update_all/3` is actually wired up, not dead code.**
  `Repo` in `auth.ex` is `alias PhoenixKit.RepoHelper, as: Repo` (not the
  raw Ecto repo), and the new code calls `Repo.update_all(query, [])` —
  i.e. it resolves through the dynamically-configured host repo, same as
  every other `Repo.*` call in this file. Confirmed this isn't a
  parallel/unused path next to the existing `Repo.repo().update_all(...)`
  call sites further down the same file.
- **NULL-propagation on the jsonb `||`/`-` operators.** If
  `custom_fields` were SQL `NULL` on a row, `NULL || jsonb` and
  `NULL - text` both evaluate to `NULL` in Postgres, which would silently
  wipe the column instead of erroring. Checked: the column is
  `null: true, default: '{}'::jsonb` (V18) — existing rows got backfilled
  by the `ALTER TABLE ... ADD COLUMN ... DEFAULT` at add-time, and no code
  path in this repo (`rg custom_fields:\s*nil` / `custom_fields, nil` —
  no hits) ever explicitly sets it to `nil`. Not a live bug, but the two
  new functions have no defensive `COALESCE` the way `update_user_custom_fields/3`
  effectively does (`user.custom_fields || %{}` before the old Map-based
  callers, and the changeset only ever receives a map). Worth a defensive
  `COALESCE(custom_fields, '{}'::jsonb)` if this table is ever written by
  something outside `Auth`'s own functions (e.g. a bulk import script) —
  not fixed here since there's no current path that triggers it.
- **`ensure_definitions_exist/1` ordering** — runs before the atomic
  `UPDATE` in both the old and new code paths; no change in when
  field-definition registration happens relative to the actual write.
- **`custom_fields_changeset/2`'s `validate_custom_fields/1`** is a bare
  `is_map` check, redundant with `merge_user_custom_fields/3`'s own
  `when is_map(additions)` guard — confirmed no validation logic is lost
  by bypassing the changeset for the two new atomic paths.
- **`delete_user_custom_field/3` removing an absent key** already always
  issues the atomic `UPDATE` regardless of whether the key exists (no
  existence check — that would reintroduce a read step and defeat the
  point of doing this atomically). This was true before my fix too; the
  fix just means that pre-existing always-write behavior now also
  correctly bumps `updated_at`, consistent with "any row this function
  touches gets a fresh `updated_at`."
- **SQL injection** — `type(^additions, :map)` and `^key` are both
  Ecto query parameters (not string-interpolated), same as everywhere
  else in this file.

## Validation

`mix precommit` (format, `compile --warnings-as-errors`, `deps.unlock --check-unused`,
`credo --strict`, dialyzer) — clean. `test/integration/users/profile_test.exs`
compiles cleanly; this environment has no PostgreSQL available (per this
project's own convention — `mix precommit` is the gate, not `mix test`),
so the new/existing integration assertions themselves weren't executed
here.
