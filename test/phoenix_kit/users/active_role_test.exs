defmodule PhoenixKit.Users.ActiveRoleTest do
  @moduledoc """
  The active-role rules, with no database: every function under test takes the
  held roles and the switcher config as arguments.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role
  alias PhoenixKitWeb.Users.MultiSession

  @owner %{uuid: "role-owner", name: "Owner"}
  @admin %{uuid: "role-admin", name: "Admin"}
  @user %{uuid: "role-user", name: "User"}
  @buyer %{uuid: "role-buyer", name: "Buyer"}
  @seller %{uuid: "role-seller", name: "Seller"}
  @newsletter %{uuid: "role-newsletter", name: "Newsletter"}

  defp config(opts \\ []) do
    %{
      enabled?: Keyword.get(opts, :enabled?, true),
      sign_in_role: Keyword.get(opts, :sign_in_role, :staff_first),
      always_on: Keyword.get(opts, :always_on, [])
    }
  end

  describe "switchable?/2" do
    test "Owner and Admin are always switchable, even if listed as always-on" do
      config = config(always_on: [@owner.uuid, @admin.uuid])
      assert ActiveRole.switchable?(@owner, config)
      assert ActiveRole.switchable?(@admin, config)
    end

    test "User is never switchable" do
      refute ActiveRole.switchable?(@user, config())
    end

    test "custom roles are switchable unless listed as always-on" do
      assert ActiveRole.switchable?(@seller, config())
      refute ActiveRole.switchable?(@newsletter, config(always_on: [@newsletter.uuid]))
    end
  end

  describe "resolve/3" do
    test "the feature off never narrows" do
      assert ActiveRole.resolve([@admin, @seller], @seller.uuid, config(enabled?: false)) == nil
    end

    test "fewer than two switchable roles never narrows" do
      assert ActiveRole.resolve([@seller, @user], nil, config()) == nil
      assert ActiveRole.resolve([@admin, @user], nil, config()) == nil

      assert ActiveRole.resolve(
               [@seller, @newsletter],
               nil,
               config(always_on: [@newsletter.uuid])
             ) ==
               nil
    end

    test "a stored switchable role that is held wins" do
      assert ActiveRole.resolve([@admin, @seller, @user], @seller.uuid, config()) == @seller
    end

    test "with nothing stored: Owner, then Admin, then the first role by name" do
      assert ActiveRole.resolve([@admin, @owner, @seller], nil, config()) == @owner
      assert ActiveRole.resolve([@seller, @admin], nil, config()) == @admin
      assert ActiveRole.resolve([@seller, @buyer], nil, config()) == @buyer
    end

    test "a stored role the user does not hold is ignored" do
      assert ActiveRole.resolve([@admin, @seller], @buyer.uuid, config()) == @admin
    end

    test "a stored role that became always-on is ignored" do
      config = config(always_on: [@newsletter.uuid])

      assert ActiveRole.resolve([@admin, @seller, @newsletter], @newsletter.uuid, config) ==
               @admin
    end

    test "a stored User role is ignored" do
      assert ActiveRole.resolve([@seller, @buyer, @user], @user.uuid, config()) == @buyer
    end
  end

  describe "sign_in_role/3" do
    test "staff_first: an Admin starts as Admin whatever they used last" do
      assert ActiveRole.sign_in_role([@admin, @seller], @seller.uuid, config()) == @admin
    end

    test "staff_first: an Owner starts as Owner over Admin" do
      assert ActiveRole.sign_in_role([@admin, @owner, @seller], @admin.uuid, config()) == @owner
    end

    test "staff_first: a non-staff user continues as their last role" do
      assert ActiveRole.sign_in_role([@buyer, @seller], @seller.uuid, config()) == @seller
    end

    test "last_used: an Admin continues as their last role" do
      config = config(sign_in_role: :last_used)
      assert ActiveRole.sign_in_role([@admin, @seller], @seller.uuid, config) == @seller
    end

    test "the feature off is nil" do
      assert ActiveRole.sign_in_role([@admin, @seller], nil, config(enabled?: false)) == nil
    end
  end

  describe "effective_roles/3" do
    test "no active role keeps every held role" do
      held = [@admin, @seller, @user]
      assert ActiveRole.effective_roles(held, nil, config()) == held
    end

    test "the active role plus every always-on role" do
      held = [@admin, @newsletter, @seller, @user]
      config = config(always_on: [@newsletter.uuid])

      assert ActiveRole.effective_roles(held, @seller, config) == [@newsletter, @seller, @user]
    end
  end

  describe "parse_always_on/1" do
    test "comma-separated uuids, whitespace and blanks tolerated" do
      assert ActiveRole.parse_always_on(" a, b,,c, a ") == ["a", "b", "c"]
    end

    test "empty or non-string is an empty set" do
      assert ActiveRole.parse_always_on("") == []
      assert ActiveRole.parse_always_on(nil) == []
    end
  end

  describe "parse_location/1" do
    test "header is recognised; anything else is menu" do
      assert ActiveRole.parse_location("header") == :header
      assert ActiveRole.parse_location("menu") == :menu
      assert ActiveRole.parse_location(nil) == :menu
      assert ActiveRole.parse_location("sidebar") == :menu
    end
  end

  describe "parse_sign_in_role/1" do
    test "last_used is recognised; anything else is staff_first" do
      assert ActiveRole.parse_sign_in_role("last_used") == :last_used
      assert ActiveRole.parse_sign_in_role("staff_first") == :staff_first
      assert ActiveRole.parse_sign_in_role(nil) == :staff_first
      assert ActiveRole.parse_sign_in_role("bogus") == :staff_first
    end
  end

  describe "stored_role_uuid/1" do
    test "reads the custom field" do
      assert ActiveRole.stored_role_uuid(%User{custom_fields: %{"active_role_uuid" => "x"}}) ==
               "x"
    end

    test "missing, nil or non-string is nil" do
      assert ActiveRole.stored_role_uuid(%User{custom_fields: %{}}) == nil
      assert ActiveRole.stored_role_uuid(%User{custom_fields: nil}) == nil
      assert ActiveRole.stored_role_uuid(%User{custom_fields: %{"active_role_uuid" => 1}}) == nil
    end
  end

  describe "Scope accessors" do
    test "held_roles falls back to cached_roles for a hand-built scope" do
      scope = %Scope{authenticated?: true, cached_roles: ["Admin"]}
      assert Scope.held_roles(scope) == ["Admin"]
      refute Scope.narrowed?(scope)
    end

    test "a narrowed scope reports its active role and real roles" do
      scope = %Scope{
        authenticated?: true,
        cached_roles: ["Seller", "User"],
        held_roles: ["Admin", "Seller", "User"],
        active_role: @seller
      }

      assert Scope.active_role(scope) == @seller
      assert Scope.held_roles(scope) == ["Admin", "Seller", "User"]
      assert Scope.narrowed?(scope)
      refute Scope.has_role?(scope, "Admin")
      refute Scope.system_role?(scope)
    end

    test "switchable_roles is [] unless set" do
      assert Scope.switchable_roles(%Scope{authenticated?: true}) == []

      assert Scope.switchable_roles(%Scope{switchable_roles: [@admin, @seller]}) == [
               @admin,
               @seller
             ]

      assert Scope.switchable_roles(nil) == []
    end

    test "nil scope" do
      assert Scope.held_roles(nil) == []
      assert Scope.active_role(nil) == nil
      refute Scope.narrowed?(nil)
    end
  end

  describe "Permissions.can_edit_role_permissions?/2 while narrowed" do
    test "a role the user holds but is not acting as is still their own" do
      scope = %Scope{
        user: %User{uuid: "u1"},
        authenticated?: true,
        cached_roles: ["Seller", "User"],
        cached_permissions: MapSet.new(["users"]),
        held_roles: ["Buyer", "Seller", "User"],
        active_role: @seller
      }

      assert Permissions.can_edit_role_permissions?(scope, %Role{name: "Buyer"}) ==
               {:error, :self_role}
    end

    test "an Admin acting as a custom role cannot edit the Admin role" do
      scope = %Scope{
        user: %User{uuid: "u1"},
        authenticated?: true,
        cached_roles: ["Seller"],
        cached_permissions: MapSet.new(["users"]),
        held_roles: ["Admin", "Seller"],
        active_role: @seller
      }

      assert Permissions.can_edit_role_permissions?(scope, %Role{name: "Admin"}) ==
               {:error, :self_role}
    end
  end

  describe "MultiSession.impersonating?/1" do
    test "true only when the active token is one impersonate/2 added" do
      assert MultiSession.impersonating?(%{
               "user_token" => "t2",
               "pk_impersonated_tokens" => ["t2"]
             })

      refute MultiSession.impersonating?(%{
               "user_token" => "t1",
               "pk_impersonated_tokens" => ["t2"]
             })

      refute MultiSession.impersonating?(%{"user_token" => "t1"})
      refute MultiSession.impersonating?(%{})
    end
  end
end
