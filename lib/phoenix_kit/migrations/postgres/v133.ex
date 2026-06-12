defmodule PhoenixKit.Migrations.Postgres.V133 do
  @moduledoc """
  V133: folder-header customization columns on `phoenix_kit_media_folders`.

  Adds the fields backing the Media browser's folder hero header / "Edit header"
  panel:

    * `cover_file_uuid UUID` — background image (a normal uploaded file living in
      the folder, excluded from its visible listing).
    * `logo_file_uuid UUID` — icon/logo shown in the header.
    * `header_size TEXT DEFAULT 'medium'` — header height: small / medium / large.
    * `header_show_title`, `header_show_icon`, `header_show_creation_info`,
      `header_show_description`, `header_show_background` BOOLEAN — per-folder
      visibility toggles for each header element (default on).

  All nullable / defaulted, so existing folders render the header as before.
  Idempotent: `ADD COLUMN IF NOT EXISTS`, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    t = "#{p}phoenix_kit_media_folders"

    execute("ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS cover_file_uuid UUID")
    execute("ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS logo_file_uuid UUID")
    execute("ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_size TEXT DEFAULT 'medium'")

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_title BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_icon BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_creation_info BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_description BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_background BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '133'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    t = "#{p}phoenix_kit_media_folders"

    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_background")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_description")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_creation_info")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_icon")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_title")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_size")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS logo_file_uuid")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS cover_file_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '132'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
