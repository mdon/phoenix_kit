defmodule PhoenixKitWeb.Live.Modules.LanguagesToggleTest do
  @moduledoc """
  Pins the `toggle_default_language_no_prefix` event handler on the
  Languages admin LiveView (`/admin/settings/languages`).

  This is the user-facing flow for the site-wide URL-prefix setting:
  flipping the toggle must persist via `Languages.set_default_language_no_prefix/1`
  AND update the socket assign so the UI reflects the new state
  without a reload.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @languages_path Routes.path("/admin/settings/languages")

  setup do
    # Enable Languages module so the admin LV mounts; the default test
    # env has it disabled.
    Settings.update_setting("languages_enabled", "true")
    Languages.set_default_language_no_prefix(false)

    on_exit(fn ->
      Languages.set_default_language_no_prefix(false)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  describe "toggle_default_language_no_prefix event" do
    test "renders the toggle as unchecked by default", %{conn: conn} do
      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      {:ok, view, _html} = live(conn, @languages_path)

      assert render(view) =~ "URL Behavior"
      assert render(view) =~ "Default Language Without Prefix"
      refute toggle_checked?(view)
    end

    test "clicking the toggle persists ON and re-renders checked", %{conn: conn} do
      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      {:ok, view, _html} = live(conn, @languages_path)

      refute Languages.default_language_no_prefix?()

      view
      |> element("input[phx-click='toggle_default_language_no_prefix']")
      |> render_click()

      # DB write took effect
      assert Languages.default_language_no_prefix?()
      # Socket assign drives the checked state on the input
      assert toggle_checked?(view)
    end

    test "clicking again toggles OFF", %{conn: conn} do
      Languages.set_default_language_no_prefix(true)

      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      {:ok, view, _html} = live(conn, @languages_path)

      view
      |> element("input[phx-click='toggle_default_language_no_prefix']")
      |> render_click()

      refute Languages.default_language_no_prefix?()
      refute toggle_checked?(view)
    end

    test "mount reflects the persisted state", %{conn: conn} do
      Languages.set_default_language_no_prefix(true)

      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      {:ok, view, _html} = live(conn, @languages_path)

      assert toggle_checked?(view)
    end
  end

  # Phoenix renders `checked={true}` with surrounding whitespace from
  # the multi-line attr declaration, so simple substring assertions
  # like `=~ "checked phx-click=..."` are fragile. This helper isolates
  # the toggle's outerHTML and inspects for the `checked` attribute.
  defp toggle_checked?(view) do
    selector = "input[phx-click='toggle_default_language_no_prefix']"
    html = view |> element(selector) |> render()

    # The element is rendered as `<input ... checked ... />` with
    # arbitrary whitespace; check via regex.
    Regex.match?(~r/<input\b[^>]*\bchecked\b[^>]*>/, html)
  end
end
