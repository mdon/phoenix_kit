defmodule PhoenixKit.Migrations.Postgres.V128 do
  @moduledoc """
  V128: Assignee on projects (and sub-projects).

  Lets a whole project be assigned to a Department / Team / Person, exactly like
  a task (`phoenix_kit_project_assignments`) already can. Because a sub-project
  *is* a project (V127), this single set of columns covers both top-level
  projects and sub-projects — a sub-project's assignee lives on its own project
  row.

  Adds to `phoenix_kit_projects`:

    * `assigned_team_uuid` → FK `phoenix_kit_staff_teams(uuid) ON DELETE SET NULL`
    * `assigned_department_uuid` → FK `phoenix_kit_staff_departments(uuid) ON DELETE SET NULL`
    * `assigned_person_uuid` → FK `phoenix_kit_staff_people(uuid) ON DELETE SET NULL`
    * `CHECK num_nonnulls(team, department, person) <= 1` — at most one assignee
      (the same single-assignee rule the assignments table uses).
    * a partial index per FK for "what's assigned to X" lookups.

  `ON DELETE SET NULL` so removing a team/department/person un-assigns the
  project rather than deleting it. Idempotent DO-blocks throughout.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = schema_for(prefix)

    add_assignee_column(p, schema, "assigned_team_uuid", "phoenix_kit_staff_teams")
    add_assignee_column(p, schema, "assigned_department_uuid", "phoenix_kit_staff_departments")
    add_assignee_column(p, schema, "assigned_person_uuid", "phoenix_kit_staff_people")
    add_single_assignee_check(p, schema)
    create_assignee_index(p, schema, "assigned_team_uuid", "team")
    create_assignee_index(p, schema, "assigned_department_uuid", "department")
    create_assignee_index(p, schema, "assigned_person_uuid", "person")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '128'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_assigned_person_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_assigned_department_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_assigned_team_idx")

    execute("""
    ALTER TABLE #{p}phoenix_kit_projects
      DROP CONSTRAINT IF EXISTS phoenix_kit_projects_single_assignee
    """)

    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS assigned_person_uuid")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS assigned_department_uuid")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS assigned_team_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '127'")
  end

  defp add_assignee_column(p, schema, column, target_table) do
    constraint = "phoenix_kit_projects_#{column}_fkey"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = '#{column}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects ADD COLUMN #{column} UUID;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND constraint_name = '#{constraint}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{column})
          REFERENCES #{p}#{target_table}(uuid)
          ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end

  # At most one of team/department/person set. Mirrors the assignments table's
  # `phoenix_kit_project_assignments_single_assignee` check.
  defp add_single_assignee_check(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND constraint_name = 'phoenix_kit_projects_single_assignee'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD CONSTRAINT phoenix_kit_projects_single_assignee
          CHECK (num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1);
      END IF;
    END $$;
    """)
  end

  defp create_assignee_index(p, schema, column, short) do
    index = "phoenix_kit_projects_assigned_#{short}_idx"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_projects'
          AND indexname = '#{index}'
      ) THEN
        CREATE INDEX #{index}
          ON #{p}phoenix_kit_projects (#{column})
          WHERE #{column} IS NOT NULL;
      END IF;
    END $$;
    """)
  end

  defp schema_for("public"), do: "public"
  defp schema_for(prefix), do: prefix

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
