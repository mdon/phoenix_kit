defmodule PhoenixKit.Integration.Languages.SingleLanguageModeTest do
  @moduledoc """
  A single-language site (multi-language support off) end to end: its primary
  language, the locale plug, and the first switch-on.

  Pairs with `test/phoenix_kit/utils/single_language_routes_test.exs`, which
  pins URL emission against a primed cache.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.ConnTest

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  setup do
    Settings.update_setting("languages_enabled", "false")
    :ok
  end

  describe "set_primary_language/1 while the switch is off" do
    test "with nothing configured the configuration becomes just that language" do
      assert {:ok, _} = Languages.set_primary_language("uk")

      assert Languages.primary_language_code() == "uk"

      assert %{"languages" => [%{"code" => "uk", "is_default" => true}]} =
               Settings.get_json_setting("languages_config", nil)

      assert Routes.get_default_admin_locale() == "uk"
      assert Routes.path("/cart", locale: "uk") == "/phoenix_kit/cart"

      # The site has only served clean URLs, so going multilingual keeps them.
      assert Languages.default_language_no_prefix?()
    end

    test "with a stored configuration the language is added and made default" do
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
          %{"code" => "et", "name" => "Estonian", "is_default" => false, "is_enabled" => false}
        ]
      })

      assert {:ok, _} = Languages.set_primary_language("uk")
      assert Languages.primary_language_code() == "uk"

      assert {:ok, _} = Languages.set_primary_language("et")
      assert Languages.primary_language_code() == "et"

      %{"languages" => languages} = Settings.get_json_setting("languages_config", nil)
      assert Enum.map(languages, & &1["code"]) == ["en-US", "et", "uk"]

      assert [%{"code" => "et", "is_enabled" => true}] =
               Enum.filter(languages, & &1["is_default"])

      # A configuration that already existed is not a fresh start.
      refute Languages.default_language_no_prefix?()
    end

    test "an unknown code is refused" do
      assert {:error, _} = Languages.set_primary_language("xx-nope")
    end
  end

  describe "the locale plug while the switch is off" do
    test "the old /en/ shape is redirected to the clean path, query kept" do
      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/en/cart?page=2", "en"), [])

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/cart?page=2"
    end

    test "any other language segment is redirected too" do
      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/de/users/log-in", "de"), [])

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/users/log-in"
    end

    test "a POST keeps its method and body: 307, not a 302 that replays it as a GET" do
      conn =
        build_conn(:post, "/phoenix_kit/en/users/log-in")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})
        |> Auth.validate_and_set_locale([])

      assert conn.halted
      assert conn.status == 307
      assert redirected_to(conn, 307) == "/phoenix_kit/users/log-in"
    end

    test "a GET is a plain 302" do
      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/en/cart", "en"), [])

      assert conn.status == 302
    end

    test "an invalid segment is stripped rather than swapped for the primary" do
      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/xx/users/log-in", "xx"), [])

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/users/log-in"
    end

    test "an admin URL renders as-is, under the primary language" do
      {:ok, _} = Languages.set_primary_language("uk")

      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/de/admin/users", "de"), [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "uk"
    end

    test "a URL without a segment renders under the primary language" do
      {:ok, _} = Languages.set_primary_language("uk")

      conn =
        build_conn(:get, "/phoenix_kit/cart")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{})
        |> Auth.validate_and_set_locale([])

      refute conn.halted
      assert conn.assigns.current_locale_base == "uk"
    end
  end

  describe "the locale plug on a multilingual site is unchanged" do
    test "a non-primary segment still renders in that language" do
      Settings.update_setting("languages_enabled", "true")

      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
          %{"code" => "es", "name" => "Spanish", "is_default" => false, "is_enabled" => true}
        ]
      })

      conn = Auth.validate_and_set_locale(locale_conn("/phoenix_kit/es/cart", "es"), [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "es"
    end
  end

  describe "enable_system/0 — the first switch-on" do
    test "starts from the configured default locale and keeps URLs prefixless" do
      assert {:ok, %{"languages" => [%{"code" => "en-US", "is_default" => true}]}} =
               Languages.enable_system()

      assert Languages.default_language_no_prefix?()
      assert Routes.path("/cart", locale: "en") == "/phoenix_kit/cart"
    end

    test "starts from a primary language chosen while off" do
      {:ok, _} = Languages.set_primary_language("uk")

      assert {:ok, %{"languages" => [%{"code" => "uk"}]}} = Languages.enable_system()
      assert Languages.primary_language_code() == "uk"
      assert Routes.path("/cart", locale: "uk") == "/phoenix_kit/cart"
    end

    test "leaves an explicitly stored no-prefix value alone" do
      {:ok, _} = Languages.set_default_language_no_prefix(false)

      {:ok, _} = Languages.enable_system()

      refute Languages.default_language_no_prefix?()
    end

    test "a site switched on before keeps its prefixed URLs when switched on again" do
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true}
        ]
      })

      {:ok, _} = Languages.enable_system()

      refute Languages.default_language_no_prefix?()
      assert Routes.path("/cart", locale: "en") == "/phoenix_kit/en/cart"
    end
  end

  defp locale_conn(path, locale) do
    build_conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> Map.put(:path_params, %{"locale" => locale})
  end
end
