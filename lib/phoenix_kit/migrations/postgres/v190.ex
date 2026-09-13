defmodule PhoenixKit.Migrations.Postgres.V190 do
  @moduledoc """
  V190: the active role lives on the session, and roles have an order.

  Two additive columns for `PhoenixKit.Users.ActiveRole`
  (`dev_docs/guides/2026-09-13-active-role.md`):

    * `phoenix_kit_users_tokens.active_role_uuid uuid NULL` — the role a
      **session** acts as. Per token, so a user can be Admin on one machine
      and Seller on another, an impersonation session has a role of its own,
      and a second multi-session account starts fresh. `NULL` means "the
      default": the first switchable role the user holds, in role order.
      Nothing is written until the user actually switches. No foreign key:
      the value is validated on every read (`ActiveRole.resolve/3` only ever
      returns a role the user still holds), a role cannot be deleted while
      assigned, and removing a role from a user revokes the sessions acting
      as it (`Roles.remove_role/3`) — so a dangling uuid cannot outlive the
      assignment that made it meaningful.

    * `phoenix_kit_user_roles.position integer NOT NULL DEFAULT 0` — the
      operator-defined role order. Seeded Owner = 0, Admin = 1, User = 2,
      custom roles after them in creation order. It decides the default
      role of a new session and the order the role switcher lists roles in;
      the Roles admin page reorders it.

  Additive only: no drops, no reshapes of anything the `ExpectedSchema`
  manifest already declares.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_users_tokens
    ADD COLUMN IF NOT EXISTS active_role_uuid uuid
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_user_roles
    ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 0
    """)

    # Seed the order once: system roles first, then custom roles as created.
    # Custom roles count from 3 (`2 + row_number()`), so the two groups never
    # share a position.
    execute("""
    UPDATE #{p}phoenix_kit_user_roles AS r
    SET position = s.pos
    FROM (
      SELECT uuid,
             CASE name
               WHEN 'Owner' THEN 0
               WHEN 'Admin' THEN 1
               WHEN 'User' THEN 2
               ELSE 2 + row_number() OVER (
                 PARTITION BY (name IN ('Owner', 'Admin', 'User'))
                 ORDER BY inserted_at, name
               )
             END AS pos
      FROM #{p}phoenix_kit_user_roles
    ) AS s
    WHERE s.uuid = r.uuid
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '190'")
  end

  @doc """
  Rolls V190 back: drops both columns.

  **Lossy:** every session falls back to the union of its user's roles (the
  pre-feature behaviour) and the operator's role order is lost.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_user_roles DROP COLUMN IF EXISTS position")
    execute("ALTER TABLE #{p}phoenix_kit_users_tokens DROP COLUMN IF EXISTS active_role_uuid")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '189'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
