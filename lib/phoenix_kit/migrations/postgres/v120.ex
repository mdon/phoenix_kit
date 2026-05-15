defmodule PhoenixKit.Migrations.Postgres.V120 do
  @moduledoc """
  V120: Document Creator Category → Type taxonomy.

  Creates two tables — `phoenix_kit_doc_categories` and
  `phoenix_kit_doc_types` — and adds nullable `category_uuid` /
  `type_uuid` FK columns to `phoenix_kit_doc_templates` and
  `phoenix_kit_doc_documents`.

  Data migration: each distinct non-empty legacy `category` string on
  templates becomes a Category row; templates are repointed via
  `category_uuid`; documents inherit their template's category.
  The legacy `category` string columns on templates and presets are
  then dropped. `type_uuid` stays NULL everywhere (no Types yet).

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_doc_categories,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true)
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
      add(:uuid, :uuid, primary_key: true)
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

    create_if_not_exists(index(:phoenix_kit_doc_types, [:category_uuid], prefix: prefix))

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
          WHERE table_name = '#{table}' AND column_name = 'category_uuid'
        ) THEN
          ALTER TABLE #{p}#{table}
            ADD COLUMN category_uuid uuid
            REFERENCES #{p}phoenix_kit_doc_categories(uuid) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'type_uuid'
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
      legacy text;
      new_uuid uuid;
      pos int := 0;
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_doc_templates'
          AND column_name = 'category'
      ) THEN
        FOR legacy IN
          SELECT DISTINCT category FROM #{p}phoenix_kit_doc_templates
          WHERE category IS NOT NULL AND category <> ''
          ORDER BY category
        LOOP
          new_uuid := gen_random_uuid();
          INSERT INTO #{p}phoenix_kit_doc_categories
            (uuid, name, position, status, data, inserted_at, updated_at)
          VALUES
            (new_uuid, initcap(legacy), pos, 'active', '{}'::jsonb, now(), now());
          UPDATE #{p}phoenix_kit_doc_templates
            SET category_uuid = new_uuid WHERE category = legacy;
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
        WHERE table_name = 'phoenix_kit_doc_template_presets'
          AND column_name = 'category'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_template_presets DROP COLUMN category;
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '120'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_doc_templates ADD COLUMN IF NOT EXISTS category varchar(255)"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_doc_template_presets ADD COLUMN IF NOT EXISTS category varchar(255)"
    )

    # Best-effort restore of the legacy string from the category name.
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_doc_categories'
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
