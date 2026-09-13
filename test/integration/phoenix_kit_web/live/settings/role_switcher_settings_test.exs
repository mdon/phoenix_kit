defmodule PhoenixKitWeb.Live.Settings.RoleSwitcherSettingsTest do
  @moduledoc """
  The Roles tab on `/admin/settings/users`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    {:ok, role} = Roles.create_role(%{name: "Newsletter#{System.unique_integer([:positive])}"})
    %{conn: log_in_user(conn, admin), role: role}
  end

  test "renders the switcher controls and offers only custom roles", %{conn: conn, role: role} do
    {:ok, _lv, html} = live(conn, Routes.path("/admin/settings/users"))

    assert html =~ ~s(name="settings[role_switcher_enabled]")
    assert html =~ ~s(name="settings[role_switcher_location]")
    assert html =~ ~s(value="#{role.uuid}")

    for system <- ~w(Owner Admin User) do
      refute html =~ ~s(value="#{Roles.get_role_by_name(system).uuid}")
    end
  end

  test "saving round-trips and joins the always-on roles", %{conn: conn, role: role} do
    {:ok, lv, _html} = live(conn, Routes.path("/admin/settings/users"))

    lv
    |> form("#user_settings_form", %{
      "settings" => %{
        "role_switcher_enabled" => "true",
        "role_switcher_location" => "header",
        "role_switcher_always_on_roles" => ["", role.uuid]
      }
    })
    |> render_submit()

    assert Settings.get_setting("role_switcher_enabled") == "true"
    assert Settings.get_setting("role_switcher_location") == "header"
    assert Settings.get_setting("role_switcher_always_on_roles") == role.uuid
  end

  test "unticking every always-on role saves an empty list", %{conn: conn, role: role} do
    Settings.update_setting("role_switcher_always_on_roles", role.uuid)

    {:ok, lv, html} = live(conn, Routes.path("/admin/settings/users"))
    assert html =~ ~r/value="#{role.uuid}"[^>]*checked/

    lv
    |> form("#user_settings_form", %{"settings" => %{"role_switcher_always_on_roles" => [""]}})
    |> render_submit()

    assert Settings.get_setting("role_switcher_always_on_roles") in ["", nil]
  end
end
