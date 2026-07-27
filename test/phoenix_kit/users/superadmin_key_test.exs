defmodule PhoenixKit.Users.SuperadminKeyTest do
  @moduledoc """
  The wildcard `"*"` superadmin permission key — a blanket, drift-immune grant
  that makes any role Owner-equivalent without enumerating keys. Pure-function
  coverage of the model (`Permissions`) and the access predicates (`Scope`).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role

  defp scope(keys), do: %Scope{cached_permissions: MapSet.new(keys), cached_roles: []}

  describe "the \"*\" key in Permissions" do
    test "superadmin_key/0 is \"*\"" do
      assert Permissions.superadmin_key() == "*"
    end

    test "is valid, always effective, in all_module_keys but NOT enabled_module_keys" do
      assert Permissions.valid_module_key?("*")
      assert Permissions.feature_enabled?("*")
      assert "*" in Permissions.all_module_keys()
      # Deliberately excluded from the grantable set so the subset arm of
      # holds_all_enabled_permissions?/1 never *requires* it.
      refute MapSet.member?(Permissions.enabled_module_keys(), "*")
    end

    test "cannot be hijacked as a custom key" do
      assert_raise ArgumentError, fn -> Permissions.register_custom_key("*") end
    end
  end

  describe "a scope holding \"*\"" do
    setup do: %{su: scope(["*"])}

    test "superadmin?/1 is true", %{su: su} do
      assert Scope.superadmin?(su)
    end

    test "has_module_access?/2 is a blanket grant — even keys never granted", %{su: su} do
      assert Scope.has_module_access?(su, "users")
      assert Scope.has_module_access?(su, "billing")
      assert Scope.has_module_access?(su, "a_module_added_next_release")
    end

    test "accessible_modules/1 surfaces the full key set (not just {\"*\"})", %{su: su} do
      # REG-2 guard: a "*"-only role must NOT collapse the Modules page / matrix
      # grantable to a single "*" entry — accessible_modules expands to all keys.
      accessible = Scope.accessible_modules(su)
      assert MapSet.member?(accessible, "users")
      assert MapSet.member?(accessible, "settings")
      assert accessible == MapSet.new(Permissions.all_module_keys())
    end

    test "has_any/has_all_module_access?/2 honor the wildcard", %{su: su} do
      assert Scope.has_any_module_access?(su, ["billing", "shop"])
      assert Scope.has_all_module_access?(su, ["billing", "shop", "users"])
    end

    test "holds_all_enabled_permissions?/1 (Owner-equivalent) is true", %{su: su} do
      assert Scope.holds_all_enabled_permissions?(su)
    end

    test "can?/2 grants any enabled key but still respects module enablement", %{su: su} do
      # Core keys are always enabled.
      assert Scope.can?(su, "users")
      # A sub-key whose parent module isn't enabled in the core test env is NOT
      # authorized: "*" is a permission grant, not a module-enablement override.
      refute Scope.can?(su, "calendar.view_others")
    end
  end

  describe "a scope WITHOUT \"*\"" do
    test "has_module_access?/2 is limited to keys actually held" do
      s = scope(["users"])
      assert Scope.superadmin?(s) == false
      assert Scope.has_module_access?(s, "users")
      refute Scope.has_module_access?(s, "billing")
    end

    test "a superadmin-only scope satisfies Owner-equivalence that a partial one does not" do
      refute Scope.holds_all_enabled_permissions?(scope(["users", "media"]))
      assert Scope.holds_all_enabled_permissions?(scope(["*"]))
    end
  end

  describe "granting \"*\" through the permissions matrix guard" do
    # Mirrors the authorization the matrix's "toggle_permission" handler runs
    # (lib/phoenix_kit_web/live/users/permissions_matrix.ex): an editor may
    # grant a key only if every key the toggle TOUCHES is a subset of the keys
    # the editor can reach (Owner ⇒ all keys; otherwise accessible_modules/1).
    # This is the privilege-escalation guard for "*": a non-superadmin must not
    # be able to mint an Owner-equivalent role.
    defp matrix_allows_grant?(editor_scope, target_key) do
      grantable =
        if Scope.owner?(editor_scope),
          do: MapSet.new(Permissions.all_module_keys()),
          else: Scope.accessible_modules(editor_scope)

      # Grant case (key absent from the target role) — same as `affected_keys/2`.
      MapSet.subset?(Permissions.expand_with_parents([target_key]), grantable)
    end

    test "the wildcard key has no parent, so a grant touches exactly that key" do
      assert Permissions.parent_key("*") == nil
      assert Permissions.expand_with_parents(["*"]) == MapSet.new(["*"])
    end

    test "a non-superadmin Admin (holds concrete keys, not \"*\") is REJECTED" do
      admin = scope(["users", "settings", "media"])
      refute Scope.superadmin?(admin)
      refute MapSet.member?(Scope.accessible_modules(admin), "*")
      refute matrix_allows_grant?(admin, "*")
    end

    test "an Owner scope is allowed to grant \"*\"" do
      roles = Role.system_roles()
      owner = %Scope{cached_roles: [roles.owner], cached_permissions: MapSet.new()}
      assert Scope.owner?(owner)
      assert matrix_allows_grant?(owner, "*")
    end

    test "a superadmin editor (already holds the wildcard) is allowed to grant it" do
      assert matrix_allows_grant?(scope(["*"]), "*")
    end
  end

  describe "can_access_admin_area?/1 (the renamed admin? entry gate)" do
    test "true for the Admin/Owner role OR any single permission; false when neither" do
      roles = Role.system_roles()

      assert Scope.can_access_admin_area?(%Scope{
               cached_roles: [roles.admin],
               cached_permissions: MapSet.new()
             })

      assert Scope.can_access_admin_area?(%Scope{
               cached_roles: [],
               cached_permissions: MapSet.new(["notifications"])
             })

      refute Scope.can_access_admin_area?(%Scope{
               cached_roles: [],
               cached_permissions: MapSet.new()
             })
    end
  end
end
