defmodule PhoenixKitWeb.Live.Modules.LanguagesPrimaryCardTest do
  @moduledoc """
  The "Primary language & URLs" card on Settings → Languages, and the line on
  Settings → General that points to it.

  The card is shown whether multi-language support is on or off: a
  single-language site needs to pick its language too, and before this card
  the only control for it was hidden behind the switch.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @languages_path Routes.path("/admin/settings/languages")
  @general_path Routes.path("/admin/settings")

  setup %{conn: conn} do
    Settings.update_setting("languages_enabled", "false")
    on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)

    {user, _token} = create_admin_user()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> log_in_user(user)

    %{conn: conn}
  end

  describe "with the switch off" do
    test "the card offers every predefined language and explains the URLs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)

      assert has_element?(view, "#primary-language-card")
      assert has_element?(view, "#primary-language-select option[value='uk']")
      assert has_element?(view, "#primary-language-select option[value='en-US'][selected]")
      assert has_element?(view, "#single-language-urls")
      refute has_element?(view, "#default-language-no-prefix-toggle")
    end

    test "picking a language makes it the primary one", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)

      view |> element("#primary-language-form") |> render_change(%{"code" => "uk"})

      assert Languages.primary_language_code() == "uk"
      refute Languages.enabled?()
      assert has_element?(view, "#primary-language-select option[value='uk'][selected]")
      assert render(view) =~ "Primary language updated"
    end

    test "an unknown code is refused and the select stays on the primary", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)

      view |> element("#primary-language-form") |> render_change(%{"code" => "xx-nope"})

      assert Languages.primary_language_code() == "en-US"
      assert render(view) =~ "Failed to set the primary language"
    end
  end

  describe "with the switch on" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("et")
      :ok
    end

    test "the card offers the enabled languages and the no-prefix toggle", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)

      assert has_element?(view, "#primary-language-select option[value='et']")
      refute has_element?(view, "#primary-language-select option[value='uk']")
      assert has_element?(view, "#default-language-no-prefix-toggle")
      refute has_element?(view, "#single-language-urls")
    end

    test "the no-prefix toggle still saves", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)
      before = Languages.default_language_no_prefix?()

      view |> element("#default-language-no-prefix-toggle") |> render_click()

      assert Languages.default_language_no_prefix?() == not before
    end

    test "picking a language moves the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, @languages_path)

      view |> element("#primary-language-form") |> render_change(%{"code" => "et"})

      assert Languages.get_default_language().code == "et"
    end
  end

  test "Settings → General names the primary language and links to the card", %{conn: conn} do
    {:ok, _} = Languages.set_primary_language("uk")

    {:ok, view, _html} = live(conn, @general_path)

    assert view |> element("#primary-language-link") |> render() =~ "Ukrainian"

    assert has_element?(
             view,
             "#primary-language-link a[href='#{@languages_path}']"
           )
  end
end
