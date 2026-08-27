defmodule Mix.Tasks.PhoenixKit.DoctorOrphanedFkTest do
  @moduledoc """
  `fk_validation_state/5` against a REAL Postgres connection — separate from
  `DoctorTest` (which stays pure per its own moduledoc: `run/1` needs the
  whole app, so that file only exercises decision functions with no repo).
  This one function is different: it already takes `repo` as an explicit
  argument, so it is a real unit-test seam without starting anything.

  RED without this fix: a genuinely
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

    test "a real, validated constraint still reads :validated" do
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

  describe "discover_fk_constraints/2 — full catalog coverage, not the old 4-pair list" do
    test "finds real FK constraints on the live schema, well beyond the old hardcoded four" do
      assert {:ok, {constraints, _skipped_multi}} =
               DoctorTask.discover_fk_constraints(Repo, "public")

      # The old check knew exactly 4 pairs. A real installed schema has far
      # more single-column FKs than that — this is the whole point of this
      # check: if this ever regresses back toward "4", the fix regressed with it.
      assert length(constraints) > 10

      assert Enum.any?(constraints, fn c ->
               c.table == "phoenix_kit_users_tokens" and c.fk_col == "user_uuid" and
                 c.ref_table == "phoenix_kit_users"
             end)

      # convalidated must be a real boolean read from the catalog, not a
      # placeholder — a stray `nil` here would silently break the
      # `if convalidated, do: :validated, else: {:not_valid, ...}` branch in
      # `probe_fk/4` for every single discovered constraint.
      assert Enum.all?(constraints, fn c -> is_boolean(c.convalidated) end)
    end

    test "a genuinely wrong schema name returns zero constraints, not an error — the caller decides that's zero coverage" do
      assert {:ok, {[], []}} =
               DoctorTask.discover_fk_constraints(Repo, "definitely_not_a_real_schema_12345")
    end

    test "a malformed schema name (real catalog-access fault) returns {:error, _}, never a silent empty list" do
      # The unescaped quote breaks the query's own string literal boundary —
      # a genuine Postgres syntax error, the same class of fault that can
      # otherwise collapse into "nothing found" and print PASS.
      assert {:error, %Postgrex.Error{}} = DoctorTask.discover_fk_constraints(Repo, "x'y")
    end
  end

  describe "fk_probe_cost_context/4 — measure, don't guess" do
    test "a real, indexed FK column reports an actual row estimate and 'indexed', not a guess" do
      context =
        DoctorTask.fk_probe_cost_context(Repo, "phoenix_kit_users_tokens", "user_uuid", "public")

      assert context =~ "phoenix_kit_users_tokens.user_uuid:"
      assert context =~ "indexed"
      refute context =~ "table likely large"
    end

    test "a nonexistent table/column pair degrades to 'row count unknown', never raises" do
      context =
        DoctorTask.fk_probe_cost_context(
          Repo,
          "definitely_not_a_real_table_12345",
          "col",
          "public"
        )

      assert context =~ "row count unknown"
    end
  end

  describe "probe timeout shape — the real error shape, not an assumed one" do
    test "a real slow query through Repo.query/3 with a short timeout is always classified as a time limit, whichever shape it takes" do
      # `probe_fk/4` calls `repo.query(sql, [], timeout: N)` — through the
      # DBConnection pool/ownership layer, not a raw `Postgrex.query/3`
      # against a bare connection. Verified live: this does NOT reliably
      # return `%Postgrex.Error{postgres: %{code: :query_canceled}}}`.
      # Depending on whether Postgres acknowledges the cancel before
      # DBConnection's own grace period expires, the identical timeout can
      # instead surface as `%DBConnection.ConnectionError{reason: :closed}}`
      # — reproduced on this same suite with both shapes occurring across
      # different runs. A test pinned to one specific shape would be flaky
      # by construction, so this asserts the real property `probe_fk/4`
      # needs: WHICHEVER shape a live timeout takes, `fk_probe_failure_reason/1`
      # recognizes it as "time limit exceeded", not a raw driver error.
      assert {:error, reason} = Repo.query("SELECT pg_sleep(3)", [], log: false, timeout: 200)

      assert match?(%Postgrex.Error{postgres: %{code: :query_canceled}}, reason) or
               match?(%DBConnection.ConnectionError{reason: :closed}, reason),
             "expected a query_canceled Postgrex.Error or a closed DBConnection.ConnectionError, " <>
               "got: #{inspect(reason)}"

      assert DoctorTask.fk_probe_failure_reason(reason) =~ "time limit exceeded"
    end
  end

  describe "discover_schema_declared_relations_without_fk/2 — I082, second step" do
    test "finds EXACTLY the real, known gap: activities.actor_uuid and .target_uuid, nothing else" do
      # Exact-list, not membership: `in` alone would still pass if a future
      # belongs_to-without-FK went unnoticed alongside these two — silently
      # absorbed into "found more than expected" instead of failing loud.
      # `_total` (every belongs_to-declared column PhoenixKit's schemas have
      # that also exists in this DB) is deliberately not asserted exactly —
      # it grows with every module that adds an association, unrelated to
      # what this test is pinning down.
      assert {:ok, {_total, missing}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      assert missing == [
               {"phoenix_kit_activities", "actor_uuid"},
               {"phoenix_kit_activities", "target_uuid"}
             ]
    end

    test "never includes a polymorphic pair — Ecto cannot declare belongs_to against a varying type" do
      assert {:ok, {_total, missing}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      # phoenix_kit_activities.resource_uuid is paired with resource_type
      # (polymorphic) — no belongs_to is declared for it in Entry's schema,
      # so it structurally cannot appear here, unlike a name-based scan
      # that would need an explicit filter to exclude it.
      refute {"phoenix_kit_activities", "resource_uuid"} in missing
    end

    test "a genuinely wrong schema name reports zero candidates, not an error" do
      assert {:ok, {0, []}} =
               DoctorTask.discover_schema_declared_relations_without_fk(
                 Repo,
                 "definitely_not_a_real_schema_12345"
               )
    end

    test "a malformed schema name (real catalog-access fault) returns {:error, _}, never a silent empty result" do
      # The unescaped quote breaks both catalog queries' own string literal
      # boundary — a genuine Postgres syntax error, the same class of fault
      # that can otherwise collapse into "nothing found" and print PASS.
      assert {:error, %Postgrex.Error{}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "x'y")
    end

    # The destructive proof-by-mutation directions — adding the FK a
    # `belongs_to` already declares must remove it from this list, and a FK
    # that exists but points at the WRONG table must NOT — live in
    # `DoctorOrphanedFkDestructiveTest`, `async: false` — see that module's
    # moduledoc for why: the real `ALTER TABLE ... ADD CONSTRAINT` it runs
    # takes a `ShareRowExclusiveLock` on `phoenix_kit_users`, which deadlocked
    # against another async test file's write to that same table on a real
    # full-suite run.
  end

  describe "check_schema_declared_relations_without_fk/1 — I082, second step: PASS is not vacuous" do
    test "reports the real count as :warn, never :fail — this is advisory, not a defect" do
      assert {:warn, message} = DoctorTask.check_schema_declared_relations_without_fk("public")
      assert message =~ "phoenix_kit_activities.actor_uuid"
      assert message =~ "phoenix_kit_activities.target_uuid"
      assert message =~ "advisory, not a failure"
    end

    test "a genuinely wrong schema name is :warn naming zero coverage, never :pass" do
      assert {:warn, message} =
               DoctorTask.check_schema_declared_relations_without_fk(
                 "definitely_not_a_real_schema_12345"
               )

      assert message =~ "coverage is zero"
      assert message =~ "not the same as clean"
    end

    test "a malformed schema name (catalog-access fault) is :warn, never :fail" do
      assert {:warn, message} = DoctorTask.check_schema_declared_relations_without_fk("x'y")
      assert message =~ "coverage is zero"
    end

    # The "closes every real gap -> :pass" destructive proof lives in
    # `DoctorOrphanedFkDestructiveTest`, `async: false` — same reason as above.
  end
end
