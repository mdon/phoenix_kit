defmodule PhoenixKit.Migrations.Postgres.V123 do
  @moduledoc """
  V123: Catalogue folders — a dedicated nesting layer for organizing
  catalogues on the admin catalogue index.

  Creates `phoenix_kit_cat_folders` (self-nesting via `parent_uuid`) and
  adds a nullable `folder_uuid` FK to `phoenix_kit_cat_catalogues` so a
  catalogue can live inside a folder (NULL = unfiled / root). These folders
  are their own thing — unrelated to the media-folder system
  (`phoenix_kit_media_folders`) — and never appear in the media browser.

  Each folder carries `position` (manual order within its parent), `status`
  (soft-delete sentinel, parity with catalogues/categories), and a `data`
  JSONB blob for future metadata. `parent_uuid` is `ON DELETE :nilify_all`
  so a hard-deleted parent orphan-promotes its children to root rather than
  cascading; `phoenix_kit_cat_catalogues.folder_uuid` is `ON DELETE SET NULL`
  for the same reason (removing a folder unfiles its catalogues, never
  deletes them).

  Also drops the global unique index on `phoenix_kit_cat_items.sku`
  (created in V87): item SKUs are **not** unique by design — the same SKU
  can legitimately appear on multiple items, even within one catalogue —
  so the partial unique index (`WHERE sku IS NOT NULL`) was an
  over-constraint that raised on duplicate SKUs. `down/1` restores it.

  All operations are idempotent (`create_if_not_exists` / `IF NOT EXISTS`
  guards) so re-running on a partially-applied schema is a no-op.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    create_if_not_exists table(:phoenix_kit_cat_folders,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("#{prefix}.uuid_generate_v7()"))
      add(:name, :string, null: false)

      add(
        :parent_uuid,
        references(:phoenix_kit_cat_folders,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:position, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "active")
      add(:data, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    # Composite index also serves parent_uuid-only lookups (leftmost
    # prefix), including the self-FK.
    create_if_not_exists(
      index(:phoenix_kit_cat_folders, [:parent_uuid, :position], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_cat_folders, [:status], prefix: prefix))

    # Nullable folder_uuid on catalogues (idempotent — column + FK may
    # already exist). NULL = unfiled (root); ON DELETE SET NULL so removing
    # a folder unfiles its catalogues rather than deleting them.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_catalogues'
          AND column_name = 'folder_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD COLUMN folder_uuid UUID
          REFERENCES #{p}phoenix_kit_cat_folders(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    create_if_not_exists(index(:phoenix_kit_cat_catalogues, [:folder_uuid], prefix: prefix))

    # Item SKUs are not unique by design — drop V87's global partial unique
    # index (default name `phoenix_kit_cat_items_sku_index`) so duplicate
    # SKUs are accepted.
    drop_if_exists(index(:phoenix_kit_cat_items, [:sku], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '123'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Restore V87's partial unique index on cat_items.sku. (Will raise if
    # duplicate SKUs were created while V123 was applied — expected when
    # rolling back a constraint relaxation onto now-violating data.)
    create_if_not_exists(
      unique_index(:phoenix_kit_cat_items, [:sku], where: "sku IS NOT NULL", prefix: prefix)
    )

    drop_if_exists(index(:phoenix_kit_cat_catalogues, [:folder_uuid], prefix: prefix))

    alter table(:phoenix_kit_cat_catalogues, prefix: prefix) do
      remove_if_exists(:folder_uuid, :uuid)
    end

    drop_if_exists(table(:phoenix_kit_cat_folders, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '122'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
