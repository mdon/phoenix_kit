defmodule PhoenixKitWeb.Live.SettingsResetTest do
  @moduledoc """
  S007 follow-up: the General settings page's "Reset to Defaults" button used
  to call `Settings.update_settings(Settings.get_defaults())` with the FULL
  defaults map — including the 5 restricted OAuth/AWS keys this page
  otherwise never loads or renders. Since `update_settings/1` writes every
  key it's handed, clicking Reset silently wiped live OAuth client secrets
  and AWS credentials, even though the confirm dialog only promises to
  replace "title, logo, formats and feature toggles".
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  test "reset_to_defaults does not touch OAuth secrets or AWS credentials", %{conn: conn} do
    {:ok, _} = Settings.update_setting("oauth_google_client_secret", "GOCSPX-live-secret")
    {:ok, _} = Settings.update_setting("aws_secret_access_key", "live-aws-secret")
    {:ok, _} = Settings.update_setting("project_title", "Custom Title")

    {admin, _token} = create_admin_user()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, Routes.path("/admin/settings"))

    lv |> element("button[phx-click=reset_to_defaults]") |> render_click()

    assert Settings.get_setting("oauth_google_client_secret") == "GOCSPX-live-secret"
    assert Settings.get_setting("aws_secret_access_key") == "live-aws-secret"
    assert Settings.get_setting("project_title") == "PhoenixKit"
  end
end
