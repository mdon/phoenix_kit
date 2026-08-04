defmodule PhoenixKitWeb.Users.AuthTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitWeb.Users.Auth

  # `permission_key_for_admin_view/1` is exposed as `@doc false def` so this
  # test can exercise the static map, the custom-tabs lookup, the
  # `PhoenixKit.Modules.*` namespace branch, and the registered-plugin
  # branch added for external modules (PhoenixKitEntities, PhoenixKitBilling, …).

  # Fixture module created with an explicit top-level name. `defmodule X` inside
  # a test gets auto-nested under the test module's namespace, which would make
  # `Module.split/1` return the wrong head segment — Module.create/3 dodges that.
  setup_all do
    Module.create(
      PhoenixKitFakePluginFixture,
      quote do
        def module_key, do: "fake_plugin"
      end,
      Macro.Env.location(__ENV__)
    )

    :ok
  end

  describe "permission_key_for_admin_view/1" do
    test "returns key from static @admin_view_permissions map" do
      assert Auth.permission_key_for_admin_view(PhoenixKitWeb.Live.Dashboard) ==
               "dashboard"

      assert Auth.permission_key_for_admin_view(PhoenixKitWeb.Live.Users.Users) ==
               "users"
    end

    test "infers key from PhoenixKit.Modules.<Name>.Web.* namespace" do
      assert Auth.permission_key_for_admin_view(PhoenixKit.Modules.Tickets.Web.Index) ==
               "tickets"

      assert Auth.permission_key_for_admin_view(PhoenixKit.Modules.NewsLetters.Web.Show) ==
               "news_letters"
    end

    test "resolves external plugin namespace via ModuleRegistry" do
      ModuleRegistry.register(PhoenixKitFakePluginFixture)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitFakePluginFixture) end)

      assert Auth.permission_key_for_admin_view(PhoenixKitFakePluginFixture.Web.Index) ==
               "fake_plugin"

      assert Auth.permission_key_for_admin_view(PhoenixKitFakePluginFixture.Web.Edit.Form) ==
               "fake_plugin"
    end

    test "returns nil for unknown views (preserves fail-closed default)" do
      assert Auth.permission_key_for_admin_view(SomeRandomUnregisteredModule) == nil
    end
  end

  describe "redirect_to_base_locale/2 carries the query string" do
    # Every locale redirect in this module rebuilds a PATH, and both
    # `conn.request_path` and `conn.path_info` stop at the "?" — so the
    # query was silently dropped while the docstring promised the
    # opposite. On this surface that costs `return_to`, which
    # `Routes.return_to_query/1` threads through exactly these URLs.
    #
    # This function is DB-free (base-code extraction is pure string work),
    # so it pins the behaviour in the no-DB unit suite; the settings-gated
    # siblings are covered in `test/integration/users/auth_locale_test.exs`.

    import Phoenix.ConnTest, only: [build_conn: 3]

    defp dialect_conn(path) do
      build_conn(:get, path, nil) |> Plug.Conn.fetch_query_params()
    end

    defp location(conn), do: Plug.Conn.get_resp_header(conn, "location") |> List.first()

    test "query parameters survive the dialect → base rewrite" do
      conn =
        "/phoenix_kit/en-US/users/log-in?return_to=%2Fadmin%2Fusers&page=2"
        |> dialect_conn()
        |> Auth.redirect_to_base_locale("en-US")

      assert conn.halted
      assert location(conn) == "/phoenix_kit/en/users/log-in?return_to=%2Fadmin%2Fusers&page=2"
    end

    test "a dialect at the end of the path keeps its query too" do
      conn =
        "/phoenix_kit/es-MX?page=2"
        |> dialect_conn()
        |> Auth.redirect_to_base_locale("es-MX")

      assert location(conn) == "/phoenix_kit/es?page=2"
    end

    test "no query string means no stray '?'" do
      conn =
        "/phoenix_kit/en-US/users/log-in"
        |> dialect_conn()
        |> Auth.redirect_to_base_locale("en-US")

      assert location(conn) == "/phoenix_kit/en/users/log-in"
    end

    test "a query Phoenix would refuse is dropped, not raised on" do
      # `Phoenix.Controller.redirect/2` raises ArgumentError on "\\",
      # "/\t" and "/%09" anywhere in the target, and a query string is
      # arbitrary client input. Truncating to the path matches what
      # shipped before; a 500 would be strictly worse.
      conn =
        "/phoenix_kit/en-US/search?q=C:%5Cwindows"
        |> dialect_conn()
        |> Map.put(:query_string, "q=C:\\windows")
        |> Auth.redirect_to_base_locale("en-US")

      assert location(conn) == "/phoenix_kit/en/search"
    end
  end
end
