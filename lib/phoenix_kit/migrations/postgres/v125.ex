defmodule PhoenixKit.Migrations.Postgres.V125 do
  @moduledoc """
  V125: Project workflow statuses (entities-backed, cement-at-start).

  Adds a user-defined "workflow status" capability to `phoenix_kit_projects`,
  orthogonal to the computed `Project.derived_status/2` lifecycle and the
  `archived_at` soft-hide. The status vocabulary is configured through the
  optional `phoenix_kit_entities` module (the "catalog"), and snapshotted into
  local projects-owned storage when a project starts (the "cement").

  Two layers:

  ## 1. Catalog reference on `phoenix_kit_projects`

  Two nullable columns let a project (or template) point at the catalog list it
  draws statuses from, and remember the currently-selected status:

    * `status_entity_uuid UUID` → FK `phoenix_kit_entities(uuid) ON DELETE SET NULL`
      — which entity (status vocabulary) this project/template uses. NULL = the
      shared default list. `ON DELETE SET NULL` so deleting a catalog entity
      degrades the project to the shared default, never cascades.
    * `current_status_slug VARCHAR(255)` — the selected status, addressed by its
      stable slug. The slug is the cross-boundary identity: pre-start it resolves
      against the live catalog rows; post-start against the cemented local rows
      below. Storing a slug (not a row UUID) avoids a foreign key whose target
      table changes at the cement boundary.

  A partial index on `(status_entity_uuid) WHERE status_entity_uuid IS NOT NULL`
  backs the "Used by N projects" reverse-reference count and grouped lookups.

  ## 2. Local cemented copy: `phoenix_kit_project_statuses`

  When a project starts, its chosen catalog statuses are copied into this table
  and the running project uses its own frozen, independently-editable copy —
  later edits to the catalog entity do NOT retroactively rewrite live projects.
  Mirrors the module's existing template→instance philosophy (an Assignment
  copies its Task template's fields at creation, then edits independently).

    * `project_uuid` → FK `phoenix_kit_projects(uuid) ON DELETE CASCADE` — the
      cemented statuses die with the project.
    * `label` / `slug` / `position` — the snapshotted status (primary-language
      label + stable slug + order).
    * `data JSONB` — per-status attributes (e.g. `{"color": "#34d399"}`).
      JSONB so colour and any future fields ride along without a migration.
    * `translations JSONB` — secondary-language label overrides, workspace
      shape `%{"es-ES" => %{"label" => "…"}}` (mirrors Project/Task/Assignment).
      Empty today; ready for status-label i18n.
    * `source_entity_data_uuid UUID` — provenance pointer back to the catalog
      `phoenix_kit_entity_data` row it was copied from. Intentionally NOT a
      foreign key: `phoenix_kit_entities` is an optional module, the cemented row
      must survive the catalog row being deleted, and the value is informational.

  Unique `(project_uuid, slug)` so a project's cemented statuses are
  slug-addressable (matching `current_status_slug`); index on `(project_uuid)`
  for list reads.

  ## 3. External identifier on `phoenix_kit_projects`

  A single nullable column lets a project be tied to a record in some external
  system, with no UI of its own (set programmatically):

    * `external_id VARCHAR(255)` — an arbitrary external reference. Deliberately
      a free-form string so it can hold a numeric id, a UUID, or a slug from
      whatever the project is being linked to. Not unique (several projects may
      reference the same external thing) and not a foreign key (the target lives
      outside this database). A partial index on
      `(external_id) WHERE external_id IS NOT NULL` backs lookup-by-external-id
      without indexing the common NULL case.

  Idempotent: re-running is a no-op once the table + columns are in the
  post-V125 shape.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = schema_for(prefix)

    create_project_statuses_table(p)
    add_status_entity_uuid_column(p, schema)
    add_status_entity_uuid_fk(p, schema)
    add_current_status_slug_column(p, schema)
    add_project_settings_column(p, schema)
    add_external_id_column(p, schema)
    create_status_entity_index(p, schema)
    create_external_id_index(p, schema)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '125'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_external_id_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_status_entity_idx")

    execute("""
    ALTER TABLE #{p}phoenix_kit_projects
      DROP CONSTRAINT IF EXISTS phoenix_kit_projects_status_entity_uuid_fkey
    """)

    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS external_id")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS settings")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS current_status_slug")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS status_entity_uuid")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_statuses")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '124'")
  end

  # The cemented per-project status rows. `IF NOT EXISTS` keeps the create
  # idempotent; `source_entity_data_uuid` is a bare UUID (no FK) on purpose —
  # the catalog lives in the optional phoenix_kit_entities package and the
  # snapshot must outlive its source.
  defp create_project_statuses_table(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_statuses (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      label VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      position INTEGER NOT NULL DEFAULT 0,
      data JSONB NOT NULL DEFAULT '{}'::jsonb,
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      source_entity_data_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_statuses_project_index
    ON #{p}phoenix_kit_project_statuses (project_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_statuses_project_slug_index
    ON #{p}phoenix_kit_project_statuses (project_uuid, slug)
    """)
  end

  defp add_status_entity_uuid_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'status_entity_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN status_entity_uuid UUID;
      END IF;
    END $$;
    """)
  end

  # FK to the catalog entity. Postgres has no `ADD CONSTRAINT IF NOT EXISTS`,
  # so guard on the constraint name. `ON DELETE SET NULL` degrades the project
  # to the shared default when its catalog entity is deleted.
  defp add_status_entity_uuid_fk(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND constraint_name = 'phoenix_kit_projects_status_entity_uuid_fkey'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD CONSTRAINT phoenix_kit_projects_status_entity_uuid_fkey
          FOREIGN KEY (status_entity_uuid)
          REFERENCES #{p}phoenix_kit_entities(uuid)
          ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end

  # Generic per-project preferences JSONB. First consumer: the
  # `use_status_translations` flag (whether to display status titles in the
  # viewer's locale). A JSONB rather than a typed column so future
  # per-project toggles ride along without another migration.
  defp add_project_settings_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'settings'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN settings JSONB NOT NULL DEFAULT '{}'::jsonb;
      END IF;
    END $$;
    """)
  end

  # Free-form external reference (no UI). A nullable string so it can carry a
  # numeric id, a UUID, or a slug from whatever system the project is linked to.
  defp add_external_id_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'external_id'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN external_id VARCHAR(255);
      END IF;
    END $$;
    """)
  end

  defp add_current_status_slug_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'current_status_slug'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN current_status_slug VARCHAR(255);
      END IF;
    END $$;
    """)
  end

  # Partial index over the projects/templates that reference a catalog entity —
  # backs the reverse-reference "Used by N projects" count and grouped status
  # resolution for list views.
  defp create_status_entity_index(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_projects'
          AND indexname = 'phoenix_kit_projects_status_entity_idx'
      ) THEN
        CREATE INDEX phoenix_kit_projects_status_entity_idx
          ON #{p}phoenix_kit_projects (status_entity_uuid)
          WHERE status_entity_uuid IS NOT NULL;
      END IF;
    END $$;
    """)
  end

  # Partial index over projects carrying an external reference — backs
  # lookup-by-external-id without indexing the common NULL case. Non-unique:
  # several projects may legitimately point at the same external record.
  defp create_external_id_index(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_projects'
          AND indexname = 'phoenix_kit_projects_external_id_idx'
      ) THEN
        CREATE INDEX phoenix_kit_projects_external_id_idx
          ON #{p}phoenix_kit_projects (external_id)
          WHERE external_id IS NOT NULL;
      END IF;
    END $$;
    """)
  end

  defp schema_for("public"), do: "public"
  defp schema_for(prefix), do: prefix

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
