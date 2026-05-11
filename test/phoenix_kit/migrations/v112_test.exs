defmodule PhoenixKit.Migrations.Postgres.V112Test do
  @moduledoc """
  Tests V112's schema state.

  V112.up/down can't be invoked outside an `Ecto.Migrator` runner — they
  rely on `Ecto.Migration.execute/1` which checks for a runner process.
  Same constraint as V106Test / V107Test. The schema itself is implicitly
  verified at boot by `test_helper.exs` which runs all migrations
  including V112 before any test runs; these assertions pin the
  post-V112 shape so a regression that drops/re-adds the wrong thing
  would surface here.

  Five changes are pinned:

  1. `archived_at TIMESTAMP(0)` on `phoenix_kit_projects` (nullable).
  2. `phoenix_kit_projects_visible_idx` partial index on
     `(inserted_at DESC) WHERE archived_at IS NULL`.
  3. `translations JSONB NOT NULL DEFAULT '{}'` on
     `phoenix_kit_projects`, `phoenix_kit_project_tasks`,
     `phoenix_kit_project_assignments`.
  4. `scheduled_start_date` is now `timestamp(0) without time zone`,
     no longer `date`.
  5. `position INTEGER NOT NULL DEFAULT 0` on `phoenix_kit_projects`
     and `phoenix_kit_project_tasks`.

  Plus the V112 drops — V106's two partial unique indexes, V101's
  global unique index, V101's task-title unique index — are all
  asserted gone, and duplicate-name inserts succeed.
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

  defp column_data_type(table, column) do
    %{rows: [[data_type]]} =
      Repo.query!(
        """
        SELECT data_type FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    data_type
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_indexes WHERE indexname = $1
        )
        """,
        [name]
      )

    exists
  end

  describe "archived_at column" do
    test "exists on phoenix_kit_projects" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'phoenix_kit_projects'
            AND column_name = 'archived_at'
        )
        """)

      assert exists == true
    end

    test "is nullable" do
      %{rows: [[is_nullable]]} =
        Repo.query!("""
        SELECT is_nullable FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_projects'
          AND column_name = 'archived_at'
        """)

      assert is_nullable == "YES"
    end

    test "has timestamp type (no timezone)" do
      assert column_data_type("phoenix_kit_projects", "archived_at") ==
               "timestamp without time zone"
    end
  end

  describe "visible-set partial index" do
    test "phoenix_kit_projects_visible_idx exists" do
      assert index_exists?("phoenix_kit_projects_visible_idx") == true
    end

    test "predicate is exactly `archived_at IS NULL` (no is_template filter)" do
      # Pinning the actual emitted predicate so the docs in
      # `postgres.ex` and the index never drift apart again. If you
      # tighten the predicate to `WHERE archived_at IS NULL AND
      # is_template = false` (split project/template indexes), update
      # both this assertion AND the moduledoc in `postgres.ex` in the
      # same change.
      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_projects_visible_idx'
        """)

      assert indexdef =~ "WHERE (archived_at IS NULL)"
      refute indexdef =~ "is_template"
    end
  end

  describe "translations JSONB columns" do
    for table <-
          ~w(phoenix_kit_projects phoenix_kit_project_tasks phoenix_kit_project_assignments) do
      test "exists on #{table} as JSONB NOT NULL DEFAULT '{}'" do
        %{rows: [[data_type, is_nullable, default]]} =
          Repo.query!(
            """
            SELECT data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_name = $1 AND column_name = 'translations'
            """,
            [unquote(table)]
          )

        assert data_type == "jsonb"
        assert is_nullable == "NO"
        assert default =~ ~r/'\{\}'::jsonb/
      end
    end
  end

  describe "scheduled_start_date retype" do
    test "is now timestamp(0), not date" do
      assert column_data_type("phoenix_kit_projects", "scheduled_start_date") ==
               "timestamp without time zone"
    end
  end

  describe "position columns" do
    for table <- ~w(phoenix_kit_projects phoenix_kit_project_tasks) do
      test "exists on #{table} as INTEGER NOT NULL DEFAULT 0" do
        %{rows: [[data_type, is_nullable, default]]} =
          Repo.query!(
            """
            SELECT data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_name = $1 AND column_name = 'position'
            """,
            [unquote(table)]
          )

        assert data_type == "integer"
        assert is_nullable == "NO"
        assert default == "0"
      end
    end
  end

  describe "dropped unique-name indexes" do
    test "V106's template partial index is gone" do
      assert index_exists?("phoenix_kit_projects_name_template_index") == false
    end

    test "V106's project partial index is gone" do
      assert index_exists?("phoenix_kit_projects_name_project_index") == false
    end

    test "V101's global unique-name index is gone (V106 already dropped it)" do
      assert index_exists?("phoenix_kit_projects_name_index") == false
    end

    test "V101's task-title unique index is gone" do
      assert index_exists?("phoenix_kit_project_tasks_title_index") == false
    end
  end

  describe "duplicate-name behavior after V112" do
    test "templates and real projects can share a name" do
      _template_uuid = insert_project!("Onboarding", true)
      _project_uuid = insert_project!("Onboarding", false)

      assert :ok = :ok
    end

    test "two templates with the same name coexist" do
      first = insert_project!("Quarterly Review", true)
      second = insert_project!("Quarterly Review", true)

      assert first != second
    end

    test "two real projects with the same name coexist" do
      first = insert_project!("Q4 Planning", false)
      second = insert_project!("Q4 Planning", false)

      assert first != second
    end

    test "case-only differences are allowed (no lower(name) index left)" do
      first = insert_project!("Onboarding", true)
      second = insert_project!("ONBOARDING", true)

      assert first != second
    end
  end
end
