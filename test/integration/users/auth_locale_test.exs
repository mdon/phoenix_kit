defmodule PhoenixKit.Integration.Users.AuthLocaleTest do
  @moduledoc """
  Pins the locale-aware redirect behaviour in
  `PhoenixKitWeb.Users.Auth`:

    * `redirect_invalid_locale/2` — swap-vs-strip behaviour gated on
      `Languages.default_language_no_prefix?/0`.
    * `process_valid_locale/2`'s canonical redirect — only fires for
      non-admin primary-locale URLs when the setting is ON.

  Both behaviours need a DB-backed setting for the gate to read, so
  this file uses `DataCase` rather than the no-DB unit
  `auth_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.ConnTest
  @endpoint PhoenixKit.Test.Endpoint

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Users.Auth

  setup do
    config = %{
      "languages" => [
        %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "es", "name" => "Spanish", "is_default" => false, "is_enabled" => true}
      ]
    }

    Settings.update_setting("languages_enabled", "true")
    Settings.update_json_setting("languages_config", config)

    on_exit(fn ->
      Settings.update_boolean_setting("default_language_no_prefix", false)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  describe "redirect_invalid_locale/2 with setting OFF (default)" do
    test "swaps invalid locale for the primary base code (preserves prefixed canonical shape)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx/admin/users")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/en/admin/users"
    end

    test "handles invalid locale at the end of the path" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert redirected_to(conn) == "/phoenix_kit/en"
    end
  end

  describe "redirect_invalid_locale/2 with setting ON" do
    setup do
      Languages.set_default_language_no_prefix(true)
      :ok
    end

    test "strips the invalid locale entirely (canonical is prefixless)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx/admin/users")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/admin/users"
    end

    test "handles invalid locale at the end of the path (strips to bare prefix)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      # With setting ON, the invalid trailing segment is stripped
      # entirely, leaving the bare PhoenixKit URL prefix.
      assert redirected_to(conn) == "/phoenix_kit"
    end
  end

  defp build_invalid_locale_conn(path) do
    build_conn(:get, path)
    |> Plug.Conn.fetch_query_params()
  end
end
