defmodule PhoenixKit.Users.ActiveRoleTest do
  @moduledoc """
  The active-role rules, with no database: every function under test takes the
  held roles (in role order) and the switcher config as arguments.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role

  @owner %{uuid: "role-owner", name: "Owner"}
  @admin %{uuid: "role-admin", name: "Admin"}
  @user %{uuid: "role-user", name: "User"}
  @buyer %{uuid: "role-buyer", name: "Buyer"}
  @seller %{uuid: "role-seller", name: "Seller"}
  @newsletter %{uuid: "role-newsletter", name: "Newsletter"}

  defp config(opts \\ []) do
    %{
      enabled?: Keyword.get(opts, :enabled?, true),
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

    test "nothing stored: the first switchable role in role order (the default)" do
      assert ActiveRole.resolve([@owner, @admin, @seller], nil, config()) == @owner
      assert ActiveRole.resolve([@admin, @seller], nil, config()) == @admin
      # Role order is whatever the operator set — a custom role may come first.
      assert ActiveRole.resolve([@seller, @admin], nil, config()) == @seller
      assert ActiveRole.resolve([@user, @seller, @buyer], nil, config()) == @seller
    end

    test "a stored role the user does not hold falls back to the default" do
      assert ActiveRole.resolve([@admin, @seller], @buyer.uuid, config()) == @admin
    end

    test "a stored role that became always-on is ignored" do
      config = config(always_on: [@newsletter.uuid])

      assert ActiveRole.resolve([@admin, @seller, @newsletter], @newsletter.uuid, config) ==
               @admin
    end

    test "a stored User role is ignored" do
      assert ActiveRole.resolve([@seller, @buyer, @user], @user.uuid, config()) == @seller
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

  describe "session_role_uuid/1" do
    test "reads the virtual field the token loader fills" do
      assert ActiveRole.session_role_uuid(%User{active_role_uuid: "x"}) == "x"
    end

    test "a user loaded without a session has none" do
      assert ActiveRole.session_role_uuid(%User{}) == nil
      assert ActiveRole.session_role_uuid(%User{active_role_uuid: nil}) == nil
    end
  end

  describe "narrow/2" do
    test "a single held role never reads settings" do
      assert ActiveRole.narrow(%User{active_role_uuid: "x"}, [@admin]) == {nil, [@admin], []}
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
end
