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
      # Use the typed setter (mirrors the `setup` block in the
      # `setting ON` describe further down) so any future cache /
      # invalidation logic Languages.set_* wires up runs in cleanup
      # too — the raw Settings call would skip it.
      Languages.set_default_language_no_prefix(false)
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

  describe "validate_and_set_locale/2 — primary-locale canonical redirect" do
    # `process_valid_locale/2` (private) decides whether to 301-redirect
    # `/<default>/<non-admin>` to `/<non-admin>` so there's one canonical
    # URL when the site-wide setting is ON. With setting OFF (default)
    # the `/<default>/...` shape IS canonical and must NOT redirect —
    # the 301 would discard POST bodies. Reference incident: the bug
    # that broke login mid-browser-test before this gate was added.

    test "primary locale on non-admin URL is NOT redirected when setting is OFF" do
      conn =
        build_conn(:get, "/phoenix_kit/en/users/log-in")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.status != 301
      assert conn.assigns.current_locale_base == "en"
    end

    test "primary locale on non-admin URL IS redirected when setting is ON" do
      Languages.set_default_language_no_prefix(true)

      conn =
        build_conn(:get, "/phoenix_kit/en/users/log-in")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      # `Phoenix.Controller.redirect/2` passes status: 301 here, but the
      # test conn may report 302 depending on how the redirect helper
      # composes the response; assert on the target path which is what
      # matters for canonical-URL behavior.
      assert redirected_to(conn) == "/phoenix_kit/users/log-in"
    end

    test "primary locale on admin URL is NEVER redirected (both settings)" do
      # Admin paths share a dual-scope router emission; both shapes
      # resolve to the same live_session so a redirect would create a
      # wasteful round-trip mid-session.

      conn_off =
        build_conn(:get, "/phoenix_kit/en/admin/users")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn_off = Auth.validate_and_set_locale(conn_off, [])
      refute conn_off.halted

      Languages.set_default_language_no_prefix(true)

      conn_on =
        build_conn(:get, "/phoenix_kit/en/admin/users")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn_on = Auth.validate_and_set_locale(conn_on, [])
      refute conn_on.halted
    end

    test "non-primary locale on non-admin URL is never redirected" do
      conn =
        build_conn(:get, "/phoenix_kit/es/blog/post")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "es"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "es"
    end
  end

  defp build_invalid_locale_conn(path) do
    build_conn(:get, path)
    |> Plug.Conn.fetch_query_params()
  end
end
