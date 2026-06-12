defmodule PhoenixKit.Migrations.Postgres.V133 do
  @moduledoc """
  V133: `cover_file_uuid UUID` on `phoenix_kit_media_folders`.

  Adds an optional reference to a media file used as the folder's hero/cover
  image in the Media browser header. The cover is a normal uploaded file living
  inside the folder; the browser excludes it from the folder's visible file
  listing and count. Nullable — folders show a soft folder-color gradient header
  until a cover is set.

  Idempotent: `ADD COLUMN IF NOT EXISTS`, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_media_folders ADD COLUMN IF NOT EXISTS cover_file_uuid UUID"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '133'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_media_folders DROP COLUMN IF EXISTS cover_file_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '132'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
