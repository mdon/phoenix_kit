defmodule PhoenixKit.Migrations.Postgres.V132 do
  @moduledoc """
  V132: `description TEXT` on `phoenix_kit_media_folders`.

  Adds an optional free-text description to media folders so admins (or
  anyone managing media) can add/edit a note explaining what a folder is
  for. Nullable — existing folders have no description until one is set,
  and the Media browser shows an "add a description" affordance when empty.

  Idempotent: `ADD COLUMN IF NOT EXISTS`, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_media_folders ADD COLUMN IF NOT EXISTS description TEXT")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '132'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_media_folders DROP COLUMN IF EXISTS description")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '131'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
