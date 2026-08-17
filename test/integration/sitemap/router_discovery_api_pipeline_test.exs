defmodule PhoenixKit.Integration.Sitemap.RouterDiscoveryApiPipelineTest do
  @moduledoc """
  Pins that Router Discovery skips routes served by a JSON pipeline.

  Path patterns only catch API endpoints that happen to live under `/api`.
  Two shapes routinely escape them, and both were found in a live install's
  sitemap:

    * a module mounting its API under its own prefix — `/sync/api/status`,
      declared `pipe_through [:phoenix_kit_api]`, which answers
      `application/json`;
    * a host's infrastructure endpoint outside `/api` entirely — `/caddy/ask`
      (Caddy's on-demand-TLS "ask" hook), declared `pipe_through :api`, which
      answers `404 unknown domain` to a plain GET.

  Neither is a page. The pipeline says so at declaration time, which is a
  fact about the route rather than a guess about its path.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery
  alias PhoenixKit.Settings

  @base_url "https://example.test"

  defmodule DummyController do
    @moduledoc false
    use Phoenix.Controller, formats: []

    def page(conn, _), do: conn
    def json(conn, _), do: conn
  end

  defmodule TestRouter do
    @moduledoc false
    use Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
    end

    pipeline :api do
      plug :accepts, ["json"]
    end

    # Core declares this one in `PhoenixKitWeb.Integration`; modules mount
    # their JSON endpoints through it.
    pipeline :phoenix_kit_api do
      plug :accepts, ["json"]
    end

    scope "/" do
      pipe_through :browser
      get "/about", DummyController, :page
    end

    scope "/caddy" do
      pipe_through :api
      get "/ask", DummyController, :json
    end

    scope "/sync" do
      pipe_through [:phoenix_kit_api]
      get "/api/status", DummyController, :json
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

  test "a JSON pipeline keeps a route out of the sitemap, wherever it is mounted" do
    locs = RouterDiscovery.collect(base_url: @base_url) |> Enum.map(& &1.loc) |> Enum.sort()

    assert locs == ["#{@base_url}/about"]
  end

  test "sitemap_non_page_pipelines replaces the defaults, so a host can rescue its own :api" do
    # A host whose :api pipeline serves real pages takes it off the list.
    {:ok, _} =
      Settings.update_setting("sitemap_non_page_pipelines", JSON.encode!(["phoenix_kit_api"]))

    locs = RouterDiscovery.collect(base_url: @base_url) |> Enum.map(& &1.loc) |> Enum.sort()

    assert locs == ["#{@base_url}/about", "#{@base_url}/caddy/ask"]
  end

  test "an empty sitemap_non_page_pipelines turns pipeline-based exclusion off" do
    {:ok, _} = Settings.update_setting("sitemap_non_page_pipelines", JSON.encode!([]))

    locs = RouterDiscovery.collect(base_url: @base_url) |> Enum.map(& &1.loc) |> Enum.sort()

    assert locs == [
             "#{@base_url}/about",
             "#{@base_url}/caddy/ask",
             "#{@base_url}/sync/api/status"
           ]
  end

  test "a junk element in sitemap_non_page_pipelines does not take the source down" do
    # The setting is hand-edited JSON. A non-string element used to raise inside
    # collect/1, whose rescue swallowed it and returned [] — one typo in a
    # settings field emptied the entire router-discovery source, silently.
    {:ok, _} =
      Settings.update_setting("sitemap_non_page_pipelines", JSON.encode!(["phoenix_kit_api", 1]))

    locs = RouterDiscovery.collect(base_url: @base_url) |> Enum.map(& &1.loc) |> Enum.sort()

    # The good element still filters; the junk one is ignored, not fatal.
    assert locs == ["#{@base_url}/about", "#{@base_url}/caddy/ask"]
  end

  test "default_non_page_pipelines/0 exposes the JSON pipelines it filters on" do
    defaults = RouterDiscovery.default_non_page_pipelines()

    assert :api in defaults
    assert :phoenix_kit_api in defaults
  end
end
