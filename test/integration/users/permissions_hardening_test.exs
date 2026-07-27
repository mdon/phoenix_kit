defmodule PhoenixKit.Integration.Users.PermissionsHardeningTest do
  @moduledoc """
  Post-review hardening of the permission system:

    * **F3** — the personal `integrations` key is opt-in and is NEVER
      auto-granted to Admin (while the website-wide `integrations_system` key
      still is).
    * **F5** — user-initiated permission mutations write a durable audit trail;
      actor-less (boot/auto) grants do not.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defp unique_email, do: "pk_hardening_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    user
  end

  defp role_uuid(name), do: Enum.find(Roles.list_roles(), &(&1.name == name)).uuid

  describe "F3 — the personal `integrations` key is opt-in" do
    test "auto_grant_to_admin_roles/1 never grants `integrations` to Admin" do
      admin = role_uuid("Admin")

      assert :ok = Permissions.auto_grant_to_admin_roles("integrations")
      refute "integrations" in Permissions.get_permissions_for_role(admin)
    end

    test "the website-wide `integrations_system` key IS granted to Admin" do
      admin = role_uuid("Admin")

      assert :ok = Permissions.auto_grant_to_admin_roles("integrations_system")
      assert "integrations_system" in Permissions.get_permissions_for_role(admin)
    end
  end

  describe "F5 — audit trail on permission mutations" do
    test "grant_permission/3 with an actor logs a `permission.granted` activity" do
      actor = create_user()
      role = role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role, "dashboard", actor.uuid)

      assert %{entries: [entry]} = Activity.list(module: "permissions", resource_uuid: role)
      assert %{action: "permission.granted", module: "permissions"} = entry
      assert entry.actor_uuid == actor.uuid
    end

    test "an actor-less (boot/auto) grant writes NO audit entry" do
      role = role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role, "media", nil)
      assert %{entries: []} = Activity.list(module: "permissions", resource_uuid: role)
    end

    test "set_permissions/3 with an actor logs a `permission.synced` activity" do
      actor = create_user()
      role = role_uuid("User")

      assert :ok = Permissions.set_permissions(role, ["dashboard", "media"], actor.uuid)

      assert %{entries: [%{action: "permission.synced"} | _]} =
               Activity.list(module: "permissions", resource_uuid: role)
    end
  end
end
