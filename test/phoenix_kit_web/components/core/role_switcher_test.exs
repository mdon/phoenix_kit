defmodule PhoenixKitWeb.Components.Core.RoleSwitcherTest do
  @moduledoc """
  What the role switcher renders for a given scope. `location` is passed
  explicitly, so no test reads the setting.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Components.Core.RoleSwitcher

  @admin %{uuid: "0193a5e4-0000-7000-8000-00000000a001", name: "Admin"}
  @seller %{uuid: "0193a5e4-0000-7000-8000-00000000a002", name: "Seller"}

  defp narrowed_scope do
    %Scope{
      user: %User{uuid: "0193a5e4-0000-7000-8000-000000000001"},
      authenticated?: true,
      cached_roles: ["Seller", "User"],
      held_roles: ["Admin", "Seller", "User"],
      active_role: @seller,
      switchable_roles: [@admin, @seller]
    }
  end

  defp render_switcher(attrs) do
    render_component(&RoleSwitcher.role_switcher/1, Keyword.put_new(attrs, :id, "rs"))
  end

  describe ":menu_section" do
    test "lists the switchable roles, the active one checked and the others as forms" do
      html = render_switcher(scope: narrowed_scope(), location: :menu, current_path: "/here")

      assert html =~ "Seller"
      assert html =~ "Admin"
      assert html =~ ~s(id="rs-#{@admin.uuid}")
      assert html =~ ~s(name="role_uuid" value="#{@admin.uuid}")
      assert html =~ ~s(name="return_to" value="/here")
      assert html =~ "/users/session/role"
      # Phoenix renders the override as `name="_method" type="hidden" hidden value="put"`.
      assert html =~ ~r/name="_method"[^>]*value="put"/
      # The active role is not a form: nothing switches to the role in effect.
      refute html =~ ~s(value="#{@seller.uuid}")
      refute html =~ "sm:hidden"
    end

    test "shows only below sm when the switcher lives in the header" do
      html = render_switcher(scope: narrowed_scope(), location: :header)
      assert html =~ "sm:hidden"
    end

    test "renders nothing for a scope that is not narrowed" do
      scope = %Scope{authenticated?: true, cached_roles: ["Admin", "Seller"]}
      assert render_switcher(scope: scope, location: :menu) == ""
      assert render_switcher(scope: nil, location: :menu) == ""
    end
  end

  describe ":header" do
    test "renders nothing unless the switcher lives in the header" do
      assert render_switcher(scope: narrowed_scope(), variant: :header, location: :menu) == ""
    end

    test "a compact dropdown naming the active role, hidden below sm" do
      html = render_switcher(scope: narrowed_scope(), variant: :header, location: :header)

      assert html =~ "dropdown"
      assert html =~ "hidden sm:block"
      assert html =~ "Seller"
      assert html =~ ~s(value="#{@admin.uuid}")
    end
  end
end
