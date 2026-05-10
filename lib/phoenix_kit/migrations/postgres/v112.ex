defmodule PhoenixKit.Migrations.Postgres.V112 do
  @moduledoc """
  V112: Project lifecycle + translations + drop unique-name indexes.

  Three related changes to the `phoenix_kit_projects*` tables:

  ## 1. `archived_at` on `phoenix_kit_projects`

  Replaces the dual-purpose `status` field (which held both lifecycle
  state and a soft-hide flag) with a dedicated nullable timestamp.
  Mirrors the workspace convention used by `phoenix_kit_publishing`'s
  `posts.trashed_at` and `phoenix_kit_files.trashed_at` — null = visible,
  non-null = soft-hidden, with the timestamp doubling as audit metadata.

  The `status` column is kept (intentional — see
  `phoenix_kit_projects/AGENTS.md`) so a future workflow concept that
  legitimately wants a string lifecycle state (e.g. "paused", "blocked",
  "on_hold") can reuse the column without another migration. Application
  code stops reading or writing it; existing rows whose `status` is
  `"archived"` get backfilled into `archived_at` so the dashboard
  filters keep working transparently.

  ## 2. `translations` JSONB on the three project tables

  Adds `translations JSONB NOT NULL DEFAULT '{}'` to:

    * `phoenix_kit_projects` (Project — translatable: `name`, `description`)
    * `phoenix_kit_project_tasks` (Task — translatable: `title`, `description`)
    * `phoenix_kit_project_assignments` (Assignment — translatable:
      `description`)

  Storage shape mirrors the entities-module "settings translations"
  pattern from `PhoenixKitWeb.Components.MultilangForm`'s
  `<.translatable_field>` (the variant where `secondary_name` and
  `lang_data_key` are passed explicitly):

      %{
        "es-ES" => %{"name" => "Proyecto", "description" => "..."},
        "fr-FR" => %{"name" => "Projet"}
      }

  The primary-language values stay in their existing columns (`name`,
  `title`, `description`) — the JSONB only holds secondary-language
  overrides. Empty/missing override falls back to the primary value at
  render time. No primary-language marker key (`_primary_language`) is
  needed because the primary lives outside the JSONB.

  ## 3. Drop unique-name indexes on projects + tasks

  V105 split `phoenix_kit_projects_name_index` into two partial unique
  indexes (one per `is_template`). V112 drops both of those plus the
  unique-title index on `phoenix_kit_project_tasks` because user-input
  display names are policy, not structure: code references resources
  by `uuid`, so duplicate names across projects/templates/tasks is
  fine and the unique constraint just made common workflows (clone
  twice, two teams' "Onboarding" templates) raise a constraint error.

  Indexes removed:

    * `phoenix_kit_projects_name_template_index` (V105)
    * `phoenix_kit_projects_name_project_index` (V105)
    * `phoenix_kit_project_tasks_title_index` (V101)

  ## 4. Retype `scheduled_start_date` from `date` to `timestamp(0)`

  The "scheduled start" field originally held only a date — fine for
  the daily-cadence projects, awkward for "this campaign starts at
  09:00 sharp" or "the announcement at 14:30." V112 promotes it to
  `timestamp(0)` so the form / popup can carry hour-and-minute
  precision. Existing date values are preserved at midnight UTC.

  The column name is kept (`scheduled_start_date`) — renaming to
  `scheduled_start_at` would force every call site, the changeset
  cast list, and any in-flight URL params to chase. Lying name +
  honest type beats a churn pass; future cleanup can rename when a
  larger refactor is on the table.

  ## 5. Add `position` to `phoenix_kit_project_tasks` and `phoenix_kit_projects`

  Drives manual reorder of the task library, project list, and
  template list views. NOT NULL with a default of `0`; existing rows
  fold into the same `0` bucket and the schema's secondary
  order-by-`inserted_at` kicks in until the user actually drags. New
  rows should be inserted via `next_task_position/0` /
  `next_project_position/1` so they land at the bottom of their
  bucket.

  `phoenix_kit_projects.position` is interpreted per `is_template`
  scope — projects and templates share the same column but order
  independently (the LV sorts within `is_template = false` for the
  project list, `is_template = true` for the template list).

  Idempotent: re-running is a no-op once the columns + indexes are in
  the post-V112 shape.
  """

  use Ecto.Migration

  @translation_tables ~w(phoenix_kit_projects phoenix_kit_project_tasks phoenix_kit_project_assignments)

  @drop_unique_indexes ~w(
    phoenix_kit_projects_name_template_index
    phoenix_kit_projects_name_project_index
    phoenix_kit_project_tasks_title_index
  )

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    add_archived_at(p, schema)
    backfill_archived_at(p)
    create_visible_index(p, schema)

    Enum.each(@translation_tables, &add_translations_column(p, schema, &1))
    Enum.each(@drop_unique_indexes, &drop_index(p, &1))

    promote_scheduled_start_date_to_timestamp(p, schema)
    add_task_position_column(p, schema)
    add_project_position_column(p, schema)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '112'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS position")
    execute("ALTER TABLE #{p}phoenix_kit_project_tasks DROP COLUMN IF EXISTS position")
    demote_scheduled_start_date_to_date(p, schema_for(prefix))

    Enum.each(@translation_tables, fn table ->
      execute("ALTER TABLE #{p}#{table} DROP COLUMN IF EXISTS translations")
    end)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_visible_idx")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS archived_at")

    # Restoring the V105/V101 unique indexes on rollback so the down/up
    # round-trip lands you back where V105 + V101 left things — without
    # this, a `down(112) → up(112)` cycle would silently change the
    # constraint set. `IF NOT EXISTS` because earlier-version DBs may
    # already have these from V101/V105.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_template_index
      ON #{p}phoenix_kit_projects (lower(name))
      WHERE is_template = true
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_project_index
      ON #{p}phoenix_kit_projects (lower(name))
      WHERE is_template = false
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_tasks_title_index
      ON #{p}phoenix_kit_project_tasks (lower(title))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '111'")
  end

  defp add_archived_at(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'archived_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN archived_at TIMESTAMP(0);
      END IF;
    END $$;
    """)
  end

  # Any project currently `status='archived'` whose `archived_at` is
  # unset gets stamped with `updated_at` so the soft-hide state survives
  # the application code switch from reading `status` to reading
  # `archived_at`.
  defp backfill_archived_at(p) do
    execute("""
    UPDATE #{p}phoenix_kit_projects
       SET archived_at = COALESCE(updated_at, NOW())
     WHERE status = 'archived'
       AND archived_at IS NULL;
    """)
  end

  # Dashboard queries default to `is_nil(archived_at)`, so a partial
  # index on the visible set keeps them sub-millisecond on large project
  # tables. Mirrors the partial-index pattern used elsewhere in core.
  defp create_visible_index(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_projects'
          AND indexname = 'phoenix_kit_projects_visible_idx'
      ) THEN
        CREATE INDEX phoenix_kit_projects_visible_idx
          ON #{p}phoenix_kit_projects (inserted_at DESC)
          WHERE archived_at IS NULL;
      END IF;
    END $$;
    """)
  end

  defp add_translations_column(p, schema, table) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = '#{table}'
          AND column_name = 'translations'
      ) THEN
        ALTER TABLE #{p}#{table}
          ADD COLUMN translations JSONB NOT NULL DEFAULT '{}'::jsonb;
      END IF;
    END $$;
    """)
  end

  defp drop_index(p, index_name), do: execute("DROP INDEX IF EXISTS #{p}#{index_name}")

  defp schema_for("public"), do: "public"
  defp schema_for(prefix), do: prefix

  # Promotes `scheduled_start_date` from DATE to TIMESTAMP(0). Existing
  # rows keep their date; the `::timestamp(0)` cast lands them at
  # midnight UTC. Guard on the current data type so re-running on a
  # post-V112 DB is a no-op.
  defp promote_scheduled_start_date_to_timestamp(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'scheduled_start_date'
          AND data_type = 'date'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ALTER COLUMN scheduled_start_date
          TYPE TIMESTAMP(0)
          USING (scheduled_start_date::timestamp(0));
      END IF;
    END $$;
    """)
  end

  # Adds the manual-reorder `position` column. NOT NULL DEFAULT 0 so
  # existing rows pick up a value without a backfill — the LV's
  # secondary order-by-`inserted_at` gives them a stable rendering
  # until a user drags. Idempotent guard against the column already
  # existing.
  defp add_task_position_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_project_tasks'
          AND column_name = 'position'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_tasks
          ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
      END IF;
    END $$;
    """)
  end

  # Same shape as `add_task_position_column/2` but for the
  # `phoenix_kit_projects` table — drives manual reorder of the
  # project list and template list views. The column lives on a
  # single table; the LV scopes by `is_template` so projects and
  # templates have independent orderings.
  defp add_project_position_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'position'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
      END IF;
    END $$;
    """)
  end

  # Reverse: collapse the timestamp back to its date portion. Loses any
  # time-of-day data the user entered post-V112 — acceptable since this
  # only fires on rollback, which itself is a "throw away post-V112
  # work" operation. Guard via current data type for idempotence.
  defp demote_scheduled_start_date_to_date(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'scheduled_start_date'
          AND data_type LIKE 'timestamp%'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ALTER COLUMN scheduled_start_date
          TYPE DATE
          USING (scheduled_start_date::date);
      END IF;
    END $$;
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
