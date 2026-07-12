# PR #627 — Fine-grained sub-permissions, calendar events migration, reusable UI components

**Author:** Max Don (`mdon`) · **Base:** `main` · **Merge:** `6f290738` · **Reviewer:** Claude (Opus 4.8)
**Scope:** +3012 / −241 over 28 files — sub-permission plumbing, V141/V142 migrations, `SearchPicker`/`PopoverPanel`/`PkDialogDraft`, authorization hardening.

Reviewed post-merge against `main`. Overall this is a **high-quality, carefully-reasoned PR**: the concurrency guards, the "no orphan sub-key" invariant, and the Admin-gating change are all sound and well-tested. One gate-blocking Credo issue in the new code (fixed here); the rest are notes on record.

---

## BUG — CRITICAL / HIGH / MEDIUM

None found. The authorization core was traced end-to-end:

- **Race-free revoke authorization** (`revoke_permission/3` + matrix `affected_keys/2`) correctly rejects the concurrent-sub-grant scenario: the cascade set is re-read under a `(role, base)` advisory lock inside the transaction and checked against `authorized_keys`, so a sub-key granted after the editor's cached matrix was built cannot be stripped by a base revoke the editor isn't entitled to. Verified against the exact TOCTOU the PR claims to close.
- **Last-Owner guard** serializes every role-removal path through `count_remaining_owners/2`'s shared advisory lock; `safely_remove_role/2` and `sync_user_roles/3`'s `guard_last_owner_removal/3` both run it **inside** a `repo.transaction`, so the lock is held through the subsequent delete (not released at statement end). Lock acquisition order (per-user key → global owner-guard key) is consistent across paths — no deadlock inversion.
- **`set_permissions/3`** builds `valid_keys` from `all_module_keys()` (now includes `sub_permission_keys()`), so a requested sub survives the `intersection` before `expand_with_parents/1` pulls in its base. Orphan-sub invariant holds on this path too. The added `Role` row `FOR UPDATE` lock correctly fixes the "both observe zero rows, insert disjoint sets" race.
- **Admin full-access fallback** keys on `permissions_table_ready?/0` (table presence), not row count. Traced all three cases: table missing → all keys; table present + zero rows → empty (revocation sticks); transient error → fails **closed** to empty. Matches the tests in `permissions_cascade_test.exs`.
- **Migration wiring:** V141/V142 are auto-dispatched by `execute_migration_steps/4` via `Module.concat([__MODULE__, "V#{pad}"])`; only `@current_version` (→142) + the new module files are needed — no hand-maintained list to drift. Fresh `0→142` is clean; single-step version comment recorded by each migration's own `COMMENT ON TABLE`. V141 status-constraint drop/re-add is idempotent for both fresh and extended-in-place DBs.
- **`sync_user_roles/3` return-shape change** (`{:ok, [assignments]}` → `{:ok, %{assignments, roles_before, roles_after}}`): all 5 call sites updated (`users.ex` ×2, `user_form.ex` ×3). The two `{:ok, _assignments}` sites bind the map harmlessly; the audit sites read `roles_before`/`roles_after` for the exact-delta log. No unhandled caller remains.
- **JS hooks** (`SearchPicker`, `PkDialogDraft`) remove their `document`/`window` listeners and clear timers in `destroyed()`; per-element listeners are GC'd with the node. `PopoverPanel` is pure `Phoenix.LiveView.JS` (no hook).
- **Checkbox fix** (`checked` default `nil`) is a genuine correctness fix — the old `default: false` + `assign_new` meant a field-bound checkbox always rendered unchecked.

## IMPROVEMENT — MEDIUM

1. **`grant_permission/3` failed Credo `--strict` (gate-blocking) — FIXED in this review.**
   The new inline `with` in the transaction body tripped two `--strict` refactoring
   checks at `permissions.ex:765`: *"Last clause in `with` is redundant"* and
   *"Function body is nested too deep (max depth is 3, was 4)."* Since `precommit`
   runs `credo --strict` via `quality.ci`, this **fails the gate** (my first run
   masked it because `mix … | tail` returns tail's exit code, not mix's).
   Refactored into `grant_permission_locked/4` + `do_grant/4`, dropping the
   redundant final `with` clause and one nesting level. Behavior identical
   (base-then-sub grant, rollback on either error). Gate now: Credo *found no
   issues*, Dialyzer *passed successfully*.

2. **`ModuleRegistry.sub_permission_map/0` is recomputed on every call** (incl. per-sub
   regex validation) and sits behind `Permissions.parent_key/1`, which is invoked
   in warm paths — `Scope.can?/2` (twice: `base_held?` + `feature_enabled?`),
   `expand_with_parents/1` (once per key), `valid_module_key?/1`, `module_icon/1`.
   `all_modules/0` is already `:persistent_term`-cached; `sub_permission_map/0`
   is not. With few modules this is negligible, but caching it (invalidated on
   `ModuleRegistry.register/1`, like the module list) would make `can?/2` free.
   **Not changed** — low impact, and the current call count is tiny in practice.

## NITPICK / ON RECORD

- **Behavioral change to be aware of on upgrade:** Admin is now genuinely
  permission-gated (only Owner is hard-all-access). Existing installs are covered
  by the boot-time `auto_grant_new_keys_to_admin/0` Task (grants all keys unless a
  per-key `auto_granted_perm:<key>` flag records a prior Owner revocation) and by
  the table-missing fallback. The one narrow window where Admin could see reduced
  access is a **present-but-empty** permissions table (rows manually deleted) — by
  design ("emptying the table does NOT restore full access"), and covered by test.
  Flagging only so the release note sets expectations.

- **Pre-existing, NOT this PR:** `auth.ex`'s separate `count_remaining_owners/1`
  (used by `validate_can_delete_user/2`) is a read-only pre-flight without the
  advisory lock, so the last-Owner check on the **user-delete** path keeps a
  TOCTOU edge. This PR scopes its hardening to the **role-removal** paths and
  explicitly acknowledges the bulk/other paths as follow-up; the delete path is
  orthogonal. Worth a future pass, not a blocker here.

## Gate

`mix precommit` (compile `--warnings-as-errors --all-warnings` → `deps.unlock --check-unused` → `format --check-formatted` → `credo --strict` → `dialyzer`): **green** after the `grant_permission` refactor.
