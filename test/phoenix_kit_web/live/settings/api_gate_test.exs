defmodule PhoenixKitWeb.Live.Settings.ApiGateTest do
  @moduledoc """
  Who may open Settings -> API.

  The page is gated by the `api` permission, which is opt-in for the Admin role:
  a default Admin is refused, an Admin who was granted `api` gets in, and the
  Owner always gets in.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  defp refused?(result),
    do: match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)

  defp admin_role, do: Roles.get_role_by_name("Admin")

  defp owner_conn(conn),
    do: log_in_user(conn, Auth.get_user_by_email("seed-owner@phoenixkit.test"))

  test "an Admin without the api permission is refused", %{conn: conn} do
    {admin, _token} = create_admin_user()
    refute "api" in Permissions.get_permissions_for_role(admin_role().uuid)

    assert refused?(live(log_in_user(conn, admin), @path))
  end

  test "an Admin who was granted api opens the page", %{conn: conn} do
    {admin, _token} = create_admin_user()
    {:ok, _} = Permissions.grant_permission(admin_role().uuid, "api")

    assert {:ok, view, _html} = live(log_in_user(conn, admin), @path)
    assert has_element?(view, "#api-settings-page")
  end

  test "the Owner always opens the page", %{conn: conn} do
    assert {:ok, view, _html} = live(owner_conn(conn), @path)
    assert has_element?(view, "#api-settings-page")
  end

  test "a custom role holding only api opens the page and has no Settings access", %{conn: conn} do
    {:ok, role} = Roles.create_role(%{name: "ApiOnly#{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "api")

    {:ok, user} =
      Auth.register_user(%{
        email: "api_only_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)

    assert {:ok, view, _html} = live(log_in_user(conn, user), @path)
    assert has_element?(view, "#api-settings-page")

    # `api` does not open the General settings page, which needs `settings`.
    assert refused?(live(log_in_user(conn, user), Routes.path("/admin/settings")))
  end
end
