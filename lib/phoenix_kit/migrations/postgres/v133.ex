defmodule PhoenixKit.Migrations.Postgres.V133 do
  @moduledoc """
  V133: Dashboards table.

  Backs the `phoenix_kit_dashboards` plugin module. A dashboard is a page of
  placed widgets; its layout is stored as a JSONB list of widget instances
  (`[{id, widget_key, x, y, w, h, settings}]`), read and written whole.

  Scopes:
  - `personal` — `owner_user_uuid` set; private to that user.
  - `system`   — `owner_user_uuid` NULL; visible to everyone.
  - `role`     — `role_uuid` set; visible to members of that role.

  All statements are idempotent (IF NOT EXISTS), safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_dashboards (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      title VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      owner_user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      role_uuid UUID,
      scope VARCHAR(20) NOT NULL DEFAULT 'personal',
      layout JSONB NOT NULL DEFAULT '[]',
      is_default BOOLEAN NOT NULL DEFAULT false,
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_phoenix_kit_dashboards_owner
    ON #{p}phoenix_kit_dashboards (owner_user_uuid)
    WHERE owner_user_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_phoenix_kit_dashboards_scope
    ON #{p}phoenix_kit_dashboards (scope)
    """)

    # One slug per owner for personal dashboards. System dashboards share a NULL
    # owner; Postgres treats NULLs as distinct, so this does not constrain them.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_dashboards_owner_slug_index
    ON #{p}phoenix_kit_dashboards (owner_user_uuid, slug)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '133'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_dashboards CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '132'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
