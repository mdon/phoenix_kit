defmodule PhoenixKit.Migrations.Postgres.V199 do
  @moduledoc """
  V199: a media file's title, alt text and description, per language.

  A file's title and description lived in its `metadata` map, in whatever
  language the admin typed, next to rotation, tags and the EXIF/PDF keys;
  it had no alt text at all. This version adds a column of their own on
  `phoenix_kit_files`:

    * `data` (jsonb, NOT NULL, default `{}`) — the text per language,
      `%{"en-US" => %{"title" => …, "alt" => …, "description" => …}}`

  Every language holds its own text and none is marked as primary, so a
  site that changes its primary language has nothing to convert.
  `PhoenixKit.Modules.Storage.FileDetails` is the read and write path; it
  reads the `metadata` text of a file saved before this version as its
  primary-language text, so nothing is backfilled.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V199 back: drops the column. Translations are lost; the copy of the primary-language text in `metadata` stays."
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
