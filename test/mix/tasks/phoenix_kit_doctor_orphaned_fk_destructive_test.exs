defmodule Mix.Tasks.PhoenixKit.DoctorOrphanedFkDestructiveTest do
  @moduledoc """
  Every test here runs real DDL (`ALTER TABLE ... ADD CONSTRAINT`,
  `ALTER TABLE ... DISABLE/ENABLE TRIGGER`) against `phoenix_kit_activities`,
  `phoenix_kit_user_oauth_providers`, and `phoenix_kit_users` — split out of
  `DoctorOrphanedFkTest` for exactly that reason.

  `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES` takes a
  `ShareRowExclusiveLock` on BOTH the altered table and the referenced one.
  These tests used to live in `DoctorOrphanedFkTest`, declared
  `async: true` — fine in isolation, but a live full-suite run deadlocked
  (Postgres `40P01`) between two of these DDL statements and one of the
  dozen-plus other async test files that write to `phoenix_kit_users`
  concurrently: this session's ALTER waits on a `ShareRowExclusiveLock`
  held by another async test's row lock, while that test's own next
  write waits on a lock this ALTER already holds — a real deadlock, not
  bad luck, and one the full suite could hit on any run, at random,
  depending on which async tests happened to interleave.

  ExUnit's own scheduling guarantee is the fix: every `async: true` test
  module runs first and concurrently, and every `async: false` module
  runs only after ALL of them have finished, one at a time. Moving the
  actual DDL out of the async module into this one, `async: false`,
  makes the deadlock structurally impossible rather than merely less
  likely — by the time any test here runs, nothing else in the suite is
  still touching `phoenix_kit_users` at all.
  """
  use PhoenixKit.DataCase, async: false

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
  alias PhoenixKit.Test.Repo

  describe "check_orphaned_fk_refs/1 — destructive: a genuinely orphaned row outside the old 4 pairs is caught" do
    # The widened check reads every single-column FK straight from
    # `pg_constraint` (`discover_fk_constraints/2`), not just the four pairs
    # the old check knew by name. This proves that widened coverage actually
    # catches something the old four-pair list could never have seen:
    # `phoenix_kit_user_oauth_providers.user_uuid -> phoenix_kit_users.uuid`
    # (constraint `fk_user_oauth_providers_user_uuid`) was never one of the
    # old four (`phoenix_kit_users_tokens`, `phoenix_kit_user_role_assignments`,
    # `phoenix_kit_admin_notes`, `phoenix_kit_email_events`).
    #
    # A plain `INSERT` can't produce this row — the constraint rejects a
    # nonexistent `user_uuid` immediately, and it isn't `DEFERRABLE`, so
    # `SET CONSTRAINTS ALL DEFERRED` doesn't buy anything either. Disabling
    # the child table's own triggers for one statement is the standard
    # Postgres idiom for planting a row that could otherwise only arise from
    # the same kind of bypass in production — a bulk load with constraints
    # off, a restore from an inconsistent backup, direct catalog surgery —
    # which is exactly the class of real corruption this check exists to
    # catch, not a contrived test-only shape.
    test "an orphaned phoenix_kit_user_oauth_providers.user_uuid row is reported, not read as clean" do
      Repo.query!("ALTER TABLE phoenix_kit_user_oauth_providers DISABLE TRIGGER ALL")

      Repo.query!("""
      INSERT INTO phoenix_kit_user_oauth_providers
        (user_uuid, provider, provider_uid, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'google', 'destructive-orphan-test', now(), now())
      """)

      Repo.query!("ALTER TABLE phoenix_kit_user_oauth_providers ENABLE TRIGGER ALL")

      assert {:fail, message} = DoctorTask.check_orphaned_fk_refs("public")
      assert message =~ "phoenix_kit_user_oauth_providers.user_uuid"
    end
  end

  describe "discover_schema_declared_relations_without_fk/2 — I082, second step (destructive)" do
    # Proof by destruction: adding the FK a `belongs_to` already declares
    # must remove it from this list. Runs inside the test's own sandbox
    # transaction — Postgres DDL is transactional, so nothing outside this
    # test ever sees the added constraint; no manual cleanup needed. The
    # transaction itself is real, though, and still takes a real
    # `ShareRowExclusiveLock` for its duration — hence `async: false` here.
    test "adding the matching FK constraint drops that relation out of the count" do
      before_fix = DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")
      assert {"phoenix_kit_activities", "actor_uuid"} in before_fix

      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_actor_uuid_fkey
      FOREIGN KEY (actor_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      after_fix = DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      refute {"phoenix_kit_activities", "actor_uuid"} in after_fix
      assert {"phoenix_kit_activities", "target_uuid"} in after_fix
      assert length(after_fix) == length(before_fix) - 1
    end
  end

  describe "check_schema_declared_relations_without_fk/1 — I082, second step: PASS is not vacuous (destructive)" do
    # Symmetric to the destruction check above: close BOTH real gaps and
    # confirm the check actually reads clean, not just "never fails".
    test "closing every real gap makes it :pass, not just non-:fail" do
      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_actor_uuid_fkey
      FOREIGN KEY (actor_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_target_uuid_fkey
      FOREIGN KEY (target_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      assert {:pass, message} = DoctorTask.check_schema_declared_relations_without_fk("public")
      assert message =~ "Every belongs_to"
    end
  end
end
