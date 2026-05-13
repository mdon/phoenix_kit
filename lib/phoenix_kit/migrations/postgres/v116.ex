defmodule PhoenixKit.Migrations.Postgres.V116 do
  @moduledoc """
  V116: Parent reference on entity_data.

  Adds a nullable self-referential `parent_uuid` column on
  `phoenix_kit_entity_data`, letting each data row point at another row
  of the same entity as its parent. The feature is a system field on
  every entity_data row — it is always present, optional to fill, and
  never removable by the user (it does not appear in
  `entities.fields_definition`). Existing rows stay `parent_uuid = NULL`
  and become roots; no backfill needed.

  The column is nullable (roots have no parent) with **no `ON DELETE`**
  cascade: parent/child linkage and same-entity scope are managed by
  the `PhoenixKitEntities.EntityData` context, which runs subtree
  checks inside a transaction. A DB-level cascade would bypass the
  soft-delete machinery and the activity log.

  Same-entity enforcement (a row's parent must share its `entity_uuid`)
  is a context-layer responsibility — the self-FK has no view of
  `entity_uuid`, so the changeset + context perform the lookup before
  saving.

  A plain b-tree index on `(parent_uuid)` covers the "list children"
  query used when rendering the WordPress-style indented tree. Existing
  indexes on `(entity_uuid)` and `(entity_uuid, position)` still cover
  per-entity listing and manual ordering.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    if table_exists?(:phoenix_kit_entity_data, prefix) do
      # Raw SQL — the Ecto.Migration `references/2` macro targets the
      # `:id` column by default, but `phoenix_kit_entity_data`'s PK is
      # `uuid`. Match V103's column-add shape exactly.
      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_schema = '#{schema}'
            AND table_name = 'phoenix_kit_entity_data'
            AND column_name = 'parent_uuid'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_entity_data
            ADD COLUMN parent_uuid UUID
            REFERENCES #{p}phoenix_kit_entity_data(uuid);
        END IF;
      END $$;
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_parent_index
      ON #{p}phoenix_kit_entity_data (parent_uuid)
      """)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '116'")
  end

  @doc """
  Rolls V116 back by dropping the parent index and column.

  **Lossy rollback:** the tree collapses — every row becomes a root and
  all parent linkage is lost. Back up before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    if table_exists?(:phoenix_kit_entity_data, prefix) do
      execute("DROP INDEX IF EXISTS #{p}phoenix_kit_entity_data_parent_index")

      execute("ALTER TABLE #{p}phoenix_kit_entity_data DROP COLUMN IF EXISTS parent_uuid")
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '115'")
  end

  defp table_exists?(table_name, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{prefix}'
      AND table_name = '#{table_name}'
    )
    """

    %{rows: [[exists]]} = PhoenixKit.RepoHelper.repo().query!(query)
    exists
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
