defmodule PhoenixKit.Migrations.Postgres.V120 do
  @moduledoc """
  V120: Document Creator Category → Type taxonomy.

  Creates two tables — `phoenix_kit_doc_categories` and
  `phoenix_kit_doc_types` — and adds nullable `category_uuid` /
  `type_uuid` FK columns to `phoenix_kit_doc_templates` and
  `phoenix_kit_doc_documents`.

  Data migration: each distinct non-empty legacy `category` string on
  templates becomes a Category row (matched case-insensitively, so
  `"Financial"` and `"financial"` collapse into one); templates are
  repointed via `category_uuid`; documents inherit their template's
  category. The legacy `category` string columns on templates and
  presets are then dropped. `type_uuid` stays NULL everywhere (no
  Types yet).

  Note: `phoenix_kit_doc_template_presets` does not get a
  `category_uuid` column — presets do not join the new taxonomy, and
  their legacy `category` strings are discarded (not migrated).
  Dropping the preset `category` column also drops the V117
  `phoenix_kit_doc_template_presets_scope_index`, which this migration
  recreates on `(scope_type, scope_id)`.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    create_if_not_exists table(:phoenix_kit_doc_categories,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:description, :text)
      add(:position, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "active")
      add(:data, :map, null: false, default: %{})
      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_categories, [:status], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_doc_categories, [:position], prefix: prefix))

    create_if_not_exists table(:phoenix_kit_doc_types,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:description, :text)
      add(:position, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "active")
      add(:data, :map, null: false, default: %{})

      add(
        :category_uuid,
        references(:phoenix_kit_doc_categories,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    # Composite index also serves category_uuid-only lookups (leftmost
    # prefix), including the FK — no standalone [:category_uuid] index.
    create_if_not_exists(
      index(:phoenix_kit_doc_types, [:category_uuid, :position], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_doc_types, [:status], prefix: prefix))

    # FK columns on templates and documents.
    for table <- ["phoenix_kit_doc_templates", "phoenix_kit_doc_documents"] do
      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_schema = '#{schema}'
            AND table_name = '#{table}' AND column_name = 'category_uuid'
        ) THEN
          ALTER TABLE #{p}#{table}
            ADD COLUMN category_uuid uuid
            REFERENCES #{p}phoenix_kit_doc_categories(uuid) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_schema = '#{schema}'
            AND table_name = '#{table}' AND column_name = 'type_uuid'
        ) THEN
          ALTER TABLE #{p}#{table}
            ADD COLUMN type_uuid uuid
            REFERENCES #{p}phoenix_kit_doc_types(uuid) ON DELETE SET NULL;
        END IF;
      END $$
      """)
    end

    create_if_not_exists(index(:phoenix_kit_doc_templates, [:category_uuid], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_doc_templates, [:type_uuid], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:category_uuid], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:type_uuid], prefix: prefix))

    # Data migration: legacy category strings -> Category rows.
    # Only runs if the legacy column still exists.
    execute("""
    DO $$
    DECLARE
      rec record;
      new_uuid uuid;
      pos int := 0;
      display_name text;
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_templates'
          AND column_name = 'category'
      ) THEN
        -- Group case-insensitively so 'Financial'/'financial' collapse
        -- into a single Category row instead of duplicating.
        FOR rec IN
          SELECT lower(category) AS norm, min(category) AS sample
          FROM #{p}phoenix_kit_doc_templates
          WHERE category IS NOT NULL AND category <> ''
          GROUP BY lower(category)
          ORDER BY lower(category)
        LOOP
          -- Map known values explicitly; capitalize first letter for anything else.
          display_name := CASE rec.norm
            WHEN 'financial' THEN 'Financial'
            WHEN 'technical' THEN 'Technical'
            ELSE upper(substr(rec.sample, 1, 1)) || substr(rec.sample, 2)
          END;
          new_uuid := uuid_generate_v7();
          INSERT INTO #{p}phoenix_kit_doc_categories
            (uuid, name, position, status, data, inserted_at, updated_at)
          VALUES
            (new_uuid, display_name, pos, 'active', '{}'::jsonb, now(), now());
          UPDATE #{p}phoenix_kit_doc_templates
            SET category_uuid = new_uuid WHERE lower(category) = rec.norm;
          pos := pos + 1;
        END LOOP;

        -- Documents inherit their template's category.
        UPDATE #{p}phoenix_kit_doc_documents d
          SET category_uuid = t.category_uuid
          FROM #{p}phoenix_kit_doc_templates t
          WHERE d.template_uuid = t.uuid
            AND t.category_uuid IS NOT NULL;
      END IF;
    END $$
    """)

    # Drop legacy string columns.
    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS category")

    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_template_presets'
          AND column_name = 'category'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_template_presets DROP COLUMN category;
      END IF;
    END $$
    """)

    # Dropping presets.category also dropped the V117 composite index
    # `(scope_type, scope_id, category)`. Recreate it without `category`
    # so scope-filtered preset lookups keep an index.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_presets_scope_index
    ON #{p}phoenix_kit_doc_template_presets (scope_type, scope_id)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '120'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("ALTER TABLE #{p}phoenix_kit_doc_templates ADD COLUMN IF NOT EXISTS category varchar")

    execute(
      "ALTER TABLE #{p}phoenix_kit_doc_template_presets ADD COLUMN IF NOT EXISTS category varchar"
    )

    # Restore the V117 3-column scope index now that `category` exists again
    # (up/0 left it as a 2-column index).
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_doc_template_presets_scope_index")

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_presets_scope_index
    ON #{p}phoenix_kit_doc_template_presets (scope_type, scope_id, category)
    """)

    # Best-effort restore of the legacy string from the category name.
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_categories'
      ) THEN
        UPDATE #{p}phoenix_kit_doc_templates t
          SET category = lower(c.name)
          FROM #{p}phoenix_kit_doc_categories c
          WHERE t.category_uuid = c.uuid;
      END IF;
    END $$
    """)

    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS type_uuid")

    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS category_uuid")

    execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS type_uuid")

    execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS category_uuid")

    drop_if_exists(table(:phoenix_kit_doc_types, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_categories, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '119'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
