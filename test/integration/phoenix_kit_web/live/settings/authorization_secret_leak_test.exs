defmodule PhoenixKitWeb.Live.Settings.AuthorizationSecretLeakTest do
  @moduledoc """
  S009: the Authorization settings page rendered the real OAuth client
  secrets into `value=` on `type="password"` inputs — `type="password"` only
  masks the on-screen rendering, the real value still sits in the HTML
  `value=` attribute in plaintext (view-source/DevTools).

  Because the pre-filled real secret round-tripped back through the DOM,
  editing ANY other field re-submitted it as part of the `validate_settings`
  event's full-form params (LiveView `phx-change` sends the whole form on
  every change), which Phoenix's own built-in LiveView event telemetry
  logger then wrote to the application log. There is no `filter_parameters`
  fix available here: it's a host-app `Application` env key and phoenix_kit
  is a dependency, so this can only be fixed at the root — never let the
  real secret round-trip through the DOM/event params in the first place.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @google_secret "GOCSPX-super-secret-google-value"
  @github_secret "gh-super-secret-github-value"
  @facebook_secret "fb-super-secret-facebook-value"

  setup do
    {:ok, _} = Settings.update_setting("oauth_enabled", "true")
    {:ok, _} = Settings.update_setting("oauth_google_client_secret", @google_secret)
    {:ok, _} = Settings.update_setting("oauth_github_client_secret", @github_secret)
    {:ok, _} = Settings.update_setting("oauth_facebook_app_secret", @facebook_secret)

    :ok
  end

  defp login(conn) do
    {admin, _token} = create_admin_user()
    log_in_user(conn, admin)
  end

  test "rendering the page never puts the real secrets in the HTML", %{conn: conn} do
    conn = login(conn)

    {:ok, view, html} = live(conn, Routes.path("/admin/settings/authorization"))

    refute html =~ @google_secret
    refute html =~ @github_secret
    refute html =~ @facebook_secret

    # Also true of the live-rendered state, not just the initial static markup.
    rendered = render(view)
    refute rendered =~ @google_secret
    refute rendered =~ @github_secret
    refute rendered =~ @facebook_secret
  end

  test "editing another field does not leak the real secret via HTML or logs", %{conn: conn} do
    conn = login(conn)

    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

    {html, log} =
      with_log(fn ->
        render_change(view, "validate_settings", %{
          "settings" => %{
            "oauth_enabled" => "true",
            "oauth_google_enabled" => "true",
            "oauth_google_client_id" => "new-client-id.apps.googleusercontent.com",
            "oauth_google_client_secret" => ""
          }
        })
      end)

    refute html =~ @google_secret
    refute log =~ @google_secret
  end

  test "saving with the secret fields left blank does not wipe the stored secrets", %{
    conn: conn
  } do
    conn = login(conn)

    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

    view
    |> form("#authorization_settings_form", %{
      "settings" => %{
        "oauth_google_client_secret" => "",
        "oauth_github_client_secret" => "",
        "oauth_facebook_app_secret" => ""
      }
    })
    |> render_submit()

    assert Settings.get_setting("oauth_google_client_secret") == @google_secret
    assert Settings.get_setting("oauth_github_client_secret") == @github_secret
    assert Settings.get_setting("oauth_facebook_app_secret") == @facebook_secret
  end

  test "saving with a newly typed secret updates the stored value", %{conn: conn} do
    conn = login(conn)

    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

    view
    |> form("#authorization_settings_form", %{
      "settings" => %{"oauth_google_client_secret" => "brand-new-google-secret"}
    })
    |> render_submit()

    assert Settings.get_setting("oauth_google_client_secret") == "brand-new-google-secret"
  end
end
