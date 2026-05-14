defmodule PhoenixKit.Migrations.Postgres.V119 do
  @moduledoc """
  V119: Add trash support to storage folders.

  Adds a `trashed_at` timestamp column to `phoenix_kit_media_folders`
  for soft-delete, mirroring the V99 addition on `phoenix_kit_files`.
  Folders with a non-nil `trashed_at` are in the trash bucket and can
  be restored or permanently deleted. Trashing a folder recursively
  trashes its descendants + every file inside the subtree (handled
  in `Storage.trash_folder/2`); restore reverses the operation.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_media_folders'
          AND column_name = 'trashed_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_media_folders
          ADD COLUMN trashed_at TIMESTAMPTZ;
      END IF;
    END $$;
    """)

    create_if_not_exists(
      index(:phoenix_kit_media_folders, [:trashed_at],
        prefix: prefix,
        where: "trashed_at IS NOT NULL",
        name: :phoenix_kit_media_folders_trashed_at_index
      )
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '119'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(
      index(:phoenix_kit_media_folders, [:trashed_at],
        prefix: prefix,
        name: :phoenix_kit_media_folders_trashed_at_index
      )
    )

    execute("ALTER TABLE #{p}phoenix_kit_media_folders DROP COLUMN IF EXISTS trashed_at")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '118'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
