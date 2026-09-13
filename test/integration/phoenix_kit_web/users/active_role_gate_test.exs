defmodule PhoenixKitWeb.Integration.Users.ActiveRoleGateTest do
  @moduledoc """
  The admin gates honour the active role end to end: an Admin acting as a
  custom role is turned away from admin pages by the real on_mount hook, not
  just by `Scope` predicates.
  """
  use PhoenixKitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Utils.Routes

  defp admin_with_role(role_name) do
    {:ok, user} =
      Auth.register_user(%{
        email: "active_role_gate_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, "Admin")
    {:ok, _} = Roles.assign_role(user, role_name)
    user
  end

  setup do
    {:ok, seller} = Roles.create_role(%{name: "Seller#{System.unique_integer([:positive])}"})
    Settings.update_boolean_setting("role_switcher_enabled", true)
    %{seller: seller}
  end

  test "acting as Admin reaches an admin page", %{conn: conn, seller: seller} do
    user = admin_with_role(seller.name)

    assert {:ok, _lv, _html} =
             conn |> log_in_user(user) |> live(Routes.path("/admin/settings/users"))
  end

  test "acting as a custom role is turned away from admin pages", %{conn: conn, seller: seller} do
    user = admin_with_role(seller.name)
    conn = conn |> log_in_user(user) |> act_as(seller)

    assert {:error, {kind, %{to: _to}}} = live(conn, Routes.path("/admin/settings/users"))
    assert kind in [:redirect, :live_redirect]
  end

  test "the require_admin plug turns a custom-role session away too", %{
    conn: conn,
    seller: seller
  } do
    user = admin_with_role(seller.name)
    conn = conn |> log_in_user(user) |> act_as(seller)

    conn = get(conn, Routes.path("/admin/settings/users"))
    assert redirected_to(conn)
  end

  # What `PUT /users/session/role` does, without the HTTP round-trip: the role
  # is stored on THIS conn's session token.
  defp act_as(conn, role) do
    token = get_session(conn, :user_token)

    Repo.update_all(
      from(t in UserToken, where: t.token == ^token and t.context == "session"),
      set: [active_role_uuid: role.uuid]
    )

    conn
  end
end
