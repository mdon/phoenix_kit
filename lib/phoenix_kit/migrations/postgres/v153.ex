defmodule PhoenixKit.Migrations.Postgres.V153 do
  @moduledoc """
  V153: folder header size defaults to small.

  New folders now open with a small hero header (see the schema default on
  `PhoenixKit.Modules.Storage.Folder`). This migration brings existing rows
  and the DB column default in line:

    * **Column default** `phoenix_kit_media_folders.header_size` flips from
      `'medium'` (set in V134) to `'small'`, so raw inserts match the
      changeset default.

    * **Backfill** every folder currently on `'medium'` → `'small'`.
      `'medium'` was the *old default*, so a stored `'medium'` is
      indistinguishable from "never touched" — those reset to small.
      `'large'` was never a default, so any `'large'` is a deliberate
      choice and is left alone; existing `'small'` rows are unaffected.

  There is no stored "user customised this" signal, so a folder someone
  deliberately set to `'medium'` also resets — an accepted trade-off, since
  medium and default-medium can't be told apart. Users can re-pick medium
  from the header-size control any time.

  Idempotent: the backfill's `WHERE header_size = 'medium'` and the default
  swap are safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))

    execute("""
    ALTER TABLE #{p}phoenix_kit_media_folders
    ALTER COLUMN header_size SET DEFAULT 'small'
    """)

    execute("""
    UPDATE #{p}phoenix_kit_media_folders
    SET header_size = 'small'
    WHERE header_size = 'medium'
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '153'")
  end

  @doc """
  Rolls V152 back.

  Restores the column default to `'medium'` (its V134 value). **Lossy:** the
  `medium → small` backfill is not reversed — the folders that were reset
  can't be told apart from folders genuinely on small, so their sizes stay
  as they are.
  """
  def down(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))

    execute("""
    ALTER TABLE #{p}phoenix_kit_media_folders
    ALTER COLUMN header_size SET DEFAULT 'medium'
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '152'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
