defmodule PhoenixKit.Migrations.Postgres.V134 do
  @moduledoc """
  V134: folder-header customization columns on `phoenix_kit_media_folders`.

  Adds the fields backing the Media browser's folder hero header / "Edit header"
  panel:

    * `cover_file_uuid UUID` — background image (a normal uploaded file living in
      the folder, excluded from its visible listing). FK to `phoenix_kit_files`
      with `ON DELETE SET NULL` so deleting the file self-heals the reference.
    * `logo_file_uuid UUID` — icon/logo shown in the header (same FK).
    * `header_size TEXT NOT NULL DEFAULT 'medium'` — header height: small /
      medium / large.
    * `header_show_title`, `header_show_icon`, `header_show_creator`,
      `header_show_date`, `header_show_file_count`, `header_show_description`,
      `header_show_background` BOOLEAN — per-folder visibility toggles for each
      header element (default on). Creator / date / file-count are independent
      so users can show just the pieces they want.

  All nullable / defaulted, so existing folders render the header as before.
  Idempotent: `ADD COLUMN IF NOT EXISTS` plus guarded `ADD CONSTRAINT`, safe to
  re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    t = "#{p}phoenix_kit_media_folders"

    files = "#{p}phoenix_kit_files"

    execute("ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS cover_file_uuid UUID")
    execute("ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS logo_file_uuid UUID")

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_size TEXT NOT NULL DEFAULT 'medium'"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_title BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_icon BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_creator BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_date BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_file_count BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_description BOOLEAN NOT NULL DEFAULT TRUE"
    )

    execute(
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS header_show_background BOOLEAN NOT NULL DEFAULT TRUE"
    )

    # FK cover_file_uuid / logo_file_uuid → phoenix_kit_files(uuid),
    # ON DELETE SET NULL so deleting a file the header points at self-heals the
    # reference instead of leaving it dangling. Null out any pre-existing
    # dangling values first (a dev may have set a cover then deleted the file),
    # then add the constraint only if it's missing (ADD CONSTRAINT has no
    # IF NOT EXISTS, so guard via pg_constraint scoped to this table).
    add_header_asset_fk(t, files, "cover_file_uuid")
    add_header_asset_fk(t, files, "logo_file_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '134'")
  end

  defp add_header_asset_fk(table, files, column) do
    constraint = "phoenix_kit_media_folders_#{column}_fkey"

    execute("""
    UPDATE #{table} SET #{column} = NULL
    WHERE #{column} IS NOT NULL
      AND #{column} NOT IN (SELECT uuid FROM #{files})
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{constraint}' AND conrelid = '#{table}'::regclass
      ) THEN
        ALTER TABLE #{table}
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{column}) REFERENCES #{files}(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    t = "#{p}phoenix_kit_media_folders"

    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_background")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_description")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_file_count")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_date")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_creator")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_icon")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_show_title")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS header_size")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS logo_file_uuid")
    execute("ALTER TABLE #{t} DROP COLUMN IF EXISTS cover_file_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '133'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
