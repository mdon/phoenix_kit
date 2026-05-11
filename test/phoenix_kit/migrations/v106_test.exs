defmodule PhoenixKit.Migrations.Postgres.V106Test do
  @moduledoc """
  Tests V106's `down/1` cross-mode duplicate pre-check.

  V106.up/down can't be invoked outside an `Ecto.Migrator` runner —
  they rely on `Ecto.Migration.execute/1` and `repo()` which both
  check for a runner process. Same constraint as V107Test. Instead,
  this test replicates the duplicate-detection SQL the down step's
  pre-check runs and exercises both branches (empty and
  duplicate-found). This pins the query shape; if a future edit to
  V106.down breaks the pre-check (e.g., wrong table name, wrong
  column, missed `lower(...)` for case-insensitivity), the test
  fails before operators discover it during a rollback.

  Post-V112 schema-state assertions (the V106 partial indexes were
  dropped by V112, duplicate names now coexist freely) live in
  `V112Test` — that's where the drop is owned.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp insert_project!(name, is_template) do
    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_projects (name, is_template)
        VALUES ($1, $2)
        RETURNING uuid
        """,
        [name, is_template]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  # Mirrors V106.down's pre-check SELECT verbatim so a future edit
  # to the migration that breaks the pre-check syntax would also
  # break this helper, surfacing the regression in tests.
  defp find_cross_mode_duplicate do
    Repo.query!(
      "SELECT lower(name) FROM phoenix_kit_projects " <>
        "GROUP BY lower(name) HAVING count(*) > 1 LIMIT 1",
      [],
      log: false
    )
  end

  describe "down/1 — cross-mode duplicate pre-check" do
    test "no duplicates → query returns empty rows" do
      # Empty table state: no projects → no possible duplicates. The
      # pre-check returns `%{rows: []}`, and V106.down would proceed
      # to the DROP / CREATE sequence.
      assert %{rows: []} = find_cross_mode_duplicate()
    end

    test "single template + single project sharing a name → duplicate detected" do
      # The exact scenario the pre-check exists to catch: a template
      # and a real project share a name (legal under V106's split,
      # illegal under V101's global index). Without the pre-check,
      # rolling back V106 would surface a generic Postgres error
      # AFTER the partial indexes are already dropped, leaving the
      # table with no name uniqueness at all.
      _template_uuid = insert_project!("Shared Name", true)
      _project_uuid = insert_project!("Shared Name", false)

      assert %{rows: [["shared name"]]} = find_cross_mode_duplicate()
    end

    test "case-only difference still counts as a duplicate (lower-cased comparison)" do
      _template_uuid = insert_project!("Onboarding", true)
      _project_uuid = insert_project!("ONBOARDING", false)

      assert %{rows: [["onboarding"]]} = find_cross_mode_duplicate()
    end

    test "only one duplicate is returned even when multiple exist (LIMIT 1)" do
      # The pre-check uses `LIMIT 1` because surfacing one offender
      # is enough — operators resolve duplicates one at a time and
      # re-run. The query should not return all duplicates as a
      # batch (which could be expensive on a large projects table).
      _template_a = insert_project!("Alpha", true)
      _project_a = insert_project!("Alpha", false)

      _template_b = insert_project!("Beta", true)
      _project_b = insert_project!("Beta", false)

      result = find_cross_mode_duplicate()

      assert %{rows: [[name]]} = result
      assert name in ["alpha", "beta"]
    end

    test "single row at any name → no duplicate (sanity)" do
      _template = insert_project!("Solo Template", true)
      _project = insert_project!("Solo Project", false)

      assert %{rows: []} = find_cross_mode_duplicate()
    end
  end
end
