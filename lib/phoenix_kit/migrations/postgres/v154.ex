defmodule PhoenixKit.Migrations.Postgres.V154 do
  @moduledoc """
  V154: OpenGraph templates + hierarchical assignments
  (`phoenix_kit_og` plugin).

  ## phoenix_kit_og_templates

  Reusable OG canvas designs. `canvas` is JSONB so the structure can
  grow new element types without a schema change. `preview_image_uuid`
  is an optional pointer to a rendered cached preview.

  ## phoenix_kit_og_assignments

  Binds a template to a scope inside a consumer module's hierarchy. The
  `(module_key, scope_type, scope_uuid)` triple is unique — enforced via
  a partial-index pair because PostgreSQL treats `NULL` as distinct:

  - one row per `(module, scope_type)` when `scope_uuid IS NULL` (the
    module-wide default tier)
  - one row per `(module, scope_type, scope_uuid)` when not null

  `template_uuid` cascades on delete: removing a template wipes every
  assignment that pointed at it.

  All operations are idempotent.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_og_templates (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description VARCHAR(1024),
      canvas JSONB NOT NULL DEFAULT '{}',
      preview_image_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_og_templates_name_uniq UNIQUE (name)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_og_assignments (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      module_key VARCHAR(64) NOT NULL,
      scope_type VARCHAR(32) NOT NULL,
      scope_uuid UUID,
      template_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_og_templates(uuid) ON DELETE CASCADE,
      slot_mapping JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    # If the assignments table already exists (from an earlier run that
    # shipped without slot_mapping), backfill the column so an in-place
    # re-migrate doesn't leave the schema out of sync with the code.
    execute("""
    ALTER TABLE #{p}phoenix_kit_og_assignments
    ADD COLUMN IF NOT EXISTS slot_mapping JSONB NOT NULL DEFAULT '{}'
    """)

    # Partial-index pair gives us "one row per (module, scope_type, scope_uuid)"
    # while still allowing exactly one (module, scope_type) row when scope_uuid
    # IS NULL (the module-wide default tier).
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_og_assignments_unique_scoped
    ON #{p}phoenix_kit_og_assignments (module_key, scope_type, scope_uuid)
    WHERE scope_uuid IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_og_assignments_unique_default
    ON #{p}phoenix_kit_og_assignments (module_key, scope_type)
    WHERE scope_uuid IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_og_assignments_template
    ON #{p}phoenix_kit_og_assignments (template_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '154'")
  end

  @doc """
  Rolls V154 back by dropping the two OG tables.

  **Lossy rollback:** all templates and assignments are lost. Back up
  before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_og_assignments CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_og_templates CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '153'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
