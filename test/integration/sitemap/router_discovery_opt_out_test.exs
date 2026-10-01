defmodule PhoenixKit.Integration.Sitemap.RouterDiscoveryOptOutTest do
  @moduledoc """
  A route can keep itself out of the sitemap with `metadata: %{sitemap: false}`
  — for what discovery cannot see, such as sign-in decided by a host's own
  `on_mount` dispatcher (Ratelia's account pages).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery
  alias PhoenixKit.Settings

  @base_url "https://example.test"

  defmodule DummyController do
    @moduledoc false
    use Phoenix.Controller, formats: []

    def page(conn, _), do: conn
  end

  defmodule AccountController do
    @moduledoc false
    use Phoenix.Controller, formats: []

    def show(conn, _), do: conn
  end

  defmodule TestRouter do
    @moduledoc false
    use Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
    end

    scope "/" do
      pipe_through :browser
      get "/about", DummyController, :page
      get "/account", AccountController, :show, metadata: %{sitemap: false}
      get "/pricing", DummyController, :page, metadata: %{sitemap: true}
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :router)
    Application.put_env(:phoenix_kit, :router, TestRouter)
    {:ok, _} = Settings.update_boolean_setting("sitemap_router_discovery_enabled", true)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :router, previous),
        else: Application.delete_env(:phoenix_kit, :router)
    end)

    :ok
  end

  test "a static entry naming an opted-out route's plug cannot bring it back" do
    alias PhoenixKit.Modules.Sitemap.RouteResolver

    # The static source resolves a configured plug through find_route/2.
    assert RouteResolver.find_route(DummyController) == "/about"
    assert RouteResolver.find_route(AccountController) == nil
  end

  test "sitemap: false keeps a route out; anything else leaves it in" do
    locs = RouterDiscovery.collect(base_url: @base_url) |> Enum.map(& &1.loc) |> Enum.sort()

    assert locs == ["#{@base_url}/about", "#{@base_url}/pricing"]
  end
end
