defmodule PhoenixKit.Migrations.Postgres.V125Test do
  @moduledoc """
  Tests V125's schema state — project workflow statuses.

  V125.up/down can't be invoked outside an `Ecto.Migrator` runner (they
  rely on `Ecto.Migration.execute/1` which checks for a runner process —
  same constraint as V106Test/V107Test/V112Test). The schema is verified
  at boot: `test_helper.exs` runs `ensure_current/2` (now through V125)
  before any test, so these assertions pin the post-V125 shape and a
  regression that drops/re-adds the wrong thing surfaces here. The
  `down/0` round-trip is verified separately via a standalone migrate /
  rollback script (outside the sandbox).

  Pinned:

  1. `phoenix_kit_project_statuses` table — the cemented per-project copy,
     with a `project_uuid` FK that cascades, slug-unique per project.
  2. `status_entity_uuid` (nullable UUID, FK to `phoenix_kit_entities`
     with `ON DELETE SET NULL`) + `current_status_slug` (nullable) on
     `phoenix_kit_projects`.
  3. Partial index `phoenix_kit_projects_status_entity_idx` on
     `(status_entity_uuid) WHERE status_entity_uuid IS NOT NULL`.
  4. `external_id` (nullable varchar) on `phoenix_kit_projects` plus its
     partial index `phoenix_kit_projects_external_id_idx`.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  # Returns the ON DELETE action ('a' no action, 'r' restrict, 'c' cascade,
  # 'n' set null, 'd' set default) for a named FK constraint.
  defp fk_delete_rule(constraint_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT confdeltype FROM pg_constraint WHERE conname = $1",
        [constraint_name]
      )

    case rows do
      [[rule]] -> rule
      [] -> nil
    end
  end

  describe "phoenix_kit_project_statuses table" do
    test "exists with the expected columns" do
      assert %{type: "uuid", nullable: "NO"} = column("phoenix_kit_project_statuses", "uuid")

      assert %{type: "uuid", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "project_uuid")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "label")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "slug")

      assert %{type: "integer", nullable: "NO", default: "0"} =
               column("phoenix_kit_project_statuses", "position")

      assert %{type: "jsonb", nullable: "NO"} = column("phoenix_kit_project_statuses", "data")

      assert %{type: "jsonb", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "translations")

      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_project_statuses", "source_entity_data_uuid")
    end

    test "project_uuid FK cascades on delete" do
      assert fk_delete_rule("phoenix_kit_project_statuses_project_uuid_fkey") == "c"
    end

    test "has a per-project index and a unique (project_uuid, slug) index" do
      assert index_exists?("phoenix_kit_project_statuses_project_index")
      assert index_exists?("phoenix_kit_project_statuses_project_slug_index")
    end

    test "enforces slug uniqueness within a project" do
      %{rows: [[project_bin]]} =
        Repo.query!(
          "INSERT INTO phoenix_kit_projects (name) VALUES ($1) RETURNING uuid",
          ["Status Host"]
        )

      insert = fn ->
        Repo.query!(
          "INSERT INTO phoenix_kit_project_statuses (project_uuid, label, slug) VALUES ($1, $2, $3)",
          [project_bin, "Done", "done"]
        )
      end

      assert insert.()
      assert_raise Postgrex.Error, insert
    end
  end

  describe "phoenix_kit_projects catalog columns" do
    test "status_entity_uuid is a nullable uuid" do
      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_projects", "status_entity_uuid")
    end

    test "current_status_slug is a nullable varchar" do
      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_projects", "current_status_slug")
    end

    test "settings is a JSONB NOT NULL default '{}'" do
      assert %{type: "jsonb", nullable: "NO", default: default} =
               column("phoenix_kit_projects", "settings")

      assert default =~ ~r/'\{\}'::jsonb/
    end

    test "status_entity_uuid FK sets null on delete" do
      assert fk_delete_rule("phoenix_kit_projects_status_entity_uuid_fkey") == "n"
    end

    test "partial index on status_entity_uuid exists and is predicated on NOT NULL" do
      assert index_exists?("phoenix_kit_projects_status_entity_idx")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_projects_status_entity_idx'"
        )

      assert indexdef =~ "status_entity_uuid IS NOT NULL"
    end

    test "external_id is a nullable varchar" do
      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_projects", "external_id")
    end

    test "partial index on external_id exists and is predicated on NOT NULL" do
      assert index_exists?("phoenix_kit_projects_external_id_idx")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_projects_external_id_idx'"
        )

      assert indexdef =~ "external_id IS NOT NULL"
    end
  end
end
