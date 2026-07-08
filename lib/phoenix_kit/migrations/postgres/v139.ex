defmodule PhoenixKit.Migrations.Postgres.V139 do
  @moduledoc """
  V139: Dashboard-level `config` for the dashboards plugin.

  Adds a JSONB `config` column to `phoenix_kit_dashboards` for per-dashboard
  presentation settings — currently the layout mode (`"grid"` flow vs `"free"`
  pixel placement) and pixel-mode zoom. Read/written whole, like `layout`.

  All statements are idempotent (IF NOT EXISTS), safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_dashboards
    ADD COLUMN IF NOT EXISTS config JSONB NOT NULL DEFAULT '{}'
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '139'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_dashboards DROP COLUMN IF EXISTS config")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '138'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
