defmodule Mix.Tasks.PhoenixKit.DoctorOrphanedFkTest do
  @moduledoc """
  `fk_validation_state/5` against a REAL Postgres connection — separate from
  `DoctorTest` (which stays pure per its own moduledoc: `run/1` needs the
  whole app, so that file only exercises decision functions with no repo).
  This one function is different: it already takes `repo` as an explicit
  argument, so it is a real unit-test seam without starting anything.

  RED without this round's fix (gate round 2, finding 1): a genuinely
  failing probe — forced here with a deliberately malformed identifier,
  which the un-parameterized SQL this function builds turns into a real
  Postgres syntax error — used to collapse into `:absent` (the same shape as
  "no such constraint"), which is exactly how `mix phoenix_kit.doctor`
  printed PASS for a check it never actually ran.
  """
  use PhoenixKit.DataCase, async: true

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
  alias PhoenixKit.Test.Repo

  describe "fk_validation_state/5" do
    test "a genuinely failing probe returns {:probe_failed, reason}, never :absent" do
      # The unescaped single quote breaks the query's string-literal
      # boundary — a real Postgres syntax error (42601), not a contrived
      # Elixir-level fault. Exactly the shape a permission or catalog-access
      # failure would also take: `{:error, %Postgrex.Error{}}`.
      assert {:probe_failed, %Postgrex.Error{}} =
               DoctorTask.fk_validation_state(
                 Repo,
                 "phoenix_kit_users_tokens",
                 "x'y",
                 "phoenix_kit_users",
                 "public"
               )
    end

    test "a real, validated constraint still reads :validated (unchanged by this round)" do
      assert :validated =
               DoctorTask.fk_validation_state(
                 Repo,
                 "phoenix_kit_users_tokens",
                 "user_uuid",
                 "phoenix_kit_users",
                 "public"
               )
    end

    test "a genuinely absent shape still reads :absent, not probe_failed" do
      assert :absent =
               DoctorTask.fk_validation_state(
                 Repo,
                 "phoenix_kit_users_tokens",
                 "user_uuid",
                 "phoenix_kit_user_roles",
                 "public"
               )
    end
  end

  describe "check_orphaned_fk_refs/1 — I082: the result names its own scope" do
    test "a clean run still says how many of the hardcoded list were checked, not just PASS" do
      assert {:pass, message} = DoctorTask.check_orphaned_fk_refs("public")
      assert message =~ "Declared-FK scan: 4/4"
      assert message =~ "does NOT"
      assert message =~ "not a guarantee of overall"
    end
  end

  describe "discover_schema_declared_relations_without_fk/2 — I082, second step" do
    test "finds the real, known gap: activities.actor_uuid and .target_uuid declare belongs_to with no DB FK" do
      found = DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      assert {"phoenix_kit_activities", "actor_uuid"} in found
      assert {"phoenix_kit_activities", "target_uuid"} in found
    end

    test "never includes a polymorphic pair — Ecto cannot declare belongs_to against a varying type" do
      found = DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      # phoenix_kit_activities.resource_uuid is paired with resource_type
      # (polymorphic) — no belongs_to is declared for it in Entry's schema,
      # so it structurally cannot appear here, unlike a name-based scan
      # that would need an explicit filter to exclude it.
      refute {"phoenix_kit_activities", "resource_uuid"} in found
    end

    # Proof by destruction, the other direction: adding the FK a `belongs_to`
    # already declares must remove it from this list. Runs inside the
    # test's own sandbox transaction (async: true → private connection) —
    # Postgres DDL is transactional, so nothing outside this test ever sees
    # the added constraint; no manual cleanup needed.
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

  describe "check_schema_declared_relations_without_fk/1 — I082, second step: PASS is not vacuous" do
    test "reports the real count as :warn, never :fail — this is advisory, not a defect" do
      assert {:warn, message} = DoctorTask.check_schema_declared_relations_without_fk("public")
      assert message =~ "phoenix_kit_activities.actor_uuid"
      assert message =~ "advisory, not a failure"
    end

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
