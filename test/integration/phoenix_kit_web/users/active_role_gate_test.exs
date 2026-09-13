defmodule PhoenixKitWeb.Integration.Users.ActiveRoleGateTest do
  @moduledoc """
  The admin gates honour the active role end to end: an Admin acting as a
  custom role is turned away from admin pages by the real on_mount hook, not
  just by `Scope` predicates.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
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

    {:ok, user} =
      Auth.merge_user_custom_fields(user, %{"active_role_uuid" => seller.uuid},
        ensure_definitions: false
      )

    assert {:error, {kind, %{to: _to}}} =
             conn |> log_in_user(user) |> live(Routes.path("/admin/settings/users"))

    assert kind in [:redirect, :live_redirect]
  end
end
