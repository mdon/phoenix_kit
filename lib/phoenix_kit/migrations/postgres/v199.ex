defmodule PhoenixKit.Migrations.Postgres.V199 do
  @moduledoc """
  V199: translations of a media file's title, alt text and description.

  A file's title and description live in its `metadata` map, next to
  rotation, tags and the EXIF/PDF keys that are read at the top level — so
  the multilang structure, which takes over the whole map it is written to,
  cannot go there. This version adds a column of its own on
  `phoenix_kit_files`:

    * `data` (jsonb, NOT NULL, default `{}`) — the
      `PhoenixKit.Utils.Multilang` structure for the file's translatable
      details (`_title`, `_alt`, `_description` per language)

  The primary-language text stays in `metadata`, where every existing reader
  finds it; `PhoenixKit.Modules.Storage.FileDetails` is the read and write
  path for both.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V199 back: drops the column. Translations are lost; the primary-language text in `metadata` stays."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb",
      "COMMENT ON TABLE #{p}phoenix_kit IS '199'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS data",
      "COMMENT ON TABLE #{p}phoenix_kit IS '198'"
    ]
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
