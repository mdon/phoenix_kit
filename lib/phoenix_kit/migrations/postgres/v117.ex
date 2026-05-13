defmodule PhoenixKit.Migrations.Postgres.V117 do
  @moduledoc """
  V117: Document composition — template category, document sections, template presets.

  Three schema changes for the document composition feature:

  1. ALTER `phoenix_kit_doc_templates` — adds a nullable `category :: varchar`
     column and an index on `(category)` for category-filtered queries.

  2. CREATE `phoenix_kit_doc_document_sections` — join table between documents
     and templates for multi-section composed documents. Each row represents one
     template-backed section at a specific position within a document. Supports
     per-section variable overrides (`variable_values`) and image configuration
     (`image_params`). Positions are unique per document; deleting a document
     cascades to its sections. Nullifying a template FK on delete allows the
     section to survive template removal (content would need regeneration).

  3. CREATE `phoenix_kit_doc_template_presets` — named, reusable compositions of
     template sections. Presets are scoped via `scope_type` + `scope_id` (e.g.
     `"organization"` + org uuid) and optionally categorized. The `sections`
     JSONB column stores an ordered array of section descriptors
     (`[%{template_uuid, position, variable_values, image_params}]`).

  All changes use `IF NOT EXISTS` / `DO $$ ... END $$` guards so re-running
  on a partially-applied schema is a no-op.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # 1. Add category column + index to templates
    execute("ALTER TABLE #{p}phoenix_kit_doc_templates ADD COLUMN IF NOT EXISTS category VARCHAR")

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_templates_category_index
    ON #{p}phoenix_kit_doc_templates (category)
    """)

    # 2. Create document sections table
    create_if_not_exists table(:phoenix_kit_doc_document_sections,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        default: fragment("uuid_generate_v7()"),
        null: false
      )

      add(
        :document_uuid,
        references(:phoenix_kit_doc_documents,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :template_uuid,
        references(:phoenix_kit_doc_templates,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:position, :integer, null: false)
      add(:variable_values, :map, null: false, default: %{})
      add(:image_params, :map, null: false, default: %{})
      add(:created_by_uuid, :uuid, null: false)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_doc_document_sections, [:document_uuid, :position],
        name: :phoenix_kit_doc_document_sections_doc_position_index,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_doc_document_sections, [:document_uuid], prefix: prefix)
    )

    # 3. Create template presets table
    # `sections` is a JSONB array (default '[]'::jsonb), which Ecto's
    # `:map` DSL can't express — use raw SQL for that column's default.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_doc_template_presets (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7() NOT NULL,
      name VARCHAR NOT NULL,
      description TEXT,
      category VARCHAR,
      scope_type VARCHAR,
      scope_id VARCHAR,
      sections JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID NOT NULL,
      inserted_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_presets_scope_index
    ON #{p}phoenix_kit_doc_template_presets (scope_type, scope_id, category)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '117'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_doc_template_presets, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_document_sections, prefix: prefix))

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_doc_templates_category_index")
    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS category")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '116'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
