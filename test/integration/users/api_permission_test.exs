defmodule PhoenixKit.Integration.Users.ApiPermissionTest do
  @moduledoc """
  Upgrading core must not hand the `api` permission to existing Admin roles: whoever holds
  it can mint bearer keys. The Owner always has it, and an Owner can grant it explicitly.
  """
  # async: false - the boot sweep writes settings flags and role rows shared by every test.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defp role_uuid(name), do: Enum.find(Roles.list_roles(), &(&1.name == name)).uuid

  defp admin_user do
    email = "api_perm_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    {:ok, _} = Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  defp can_api?(user), do: user |> Scope.for_user(narrow: false) |> Scope.can?("api")

  describe "the permission is not handed to existing Admin roles" do
    test "the boot sweep (auto_grant_new_keys_to_admin/0) leaves api off the Admin role" do
      admin = role_uuid("Admin")

      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      permissions = Permissions.get_permissions_for_role(admin)
      refute "api" in permissions
      # The sweep did run: the website-wide integrations key is one it grants.
      assert "integrations_system" in permissions
    end

    test "a user with the Admin role cannot use api until an Owner grants it" do
      user = admin_user()
      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      refute can_api?(user)

      assert {:ok, _} = Permissions.grant_permission(role_uuid("Admin"), "api")
      assert can_api?(user)
    end

    test "an explicit grant survives the sweep" do
      admin = role_uuid("Admin")
      {:ok, _} = Permissions.grant_permission(admin, "api")

      assert :ok = Permissions.auto_grant_new_keys_to_admin()
      assert "api" in Permissions.get_permissions_for_role(admin)
    end
  end

  describe "who has it" do
    test "the Owner always has it" do
      owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")

      assert Roles.user_has_role?(owner, "Owner")
      assert can_api?(owner)
    end

    test "an ordinary user does not" do
      email = "api_perm_user_#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})

      refute can_api?(user)
    end

    test "grant_permission/2 accepts the key, so an Owner can grant it from the matrix" do
      assert {:ok, %{module_key: "api"}} = Permissions.grant_permission(role_uuid("User"), "api")
    end
  end
end
