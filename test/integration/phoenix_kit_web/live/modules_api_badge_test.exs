defmodule PhoenixKitWeb.Live.ModulesApiBadgeTest do
  @moduledoc """
  The Modules page marks a module that declares API tools with an "API on" or "API off"
  badge, linking to the module's switch in Settings -> API.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @modules_path Routes.path("/admin/modules")

  defmodule WithTools do
    def module_key, do: "badge_with_tools"
    def module_name, do: "Badge with tools"

    def permission_metadata,
      do: %{
        key: "badge_with_tools",
        label: "Badge with tools",
        icon: "hero-puzzle-piece",
        description: "A test module."
      }

    def enabled?, do: true
    def get_config, do: %{enabled: true}

    def api_tools do
      [Tool.new!(name: "badge_with_tools.search", audience: :public, handler: {__MODULE__, :run})]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  defmodule WithoutTools do
    def module_key, do: "badge_without_tools"
    def module_name, do: "Badge without tools"

    def permission_metadata,
      do: %{
        key: "badge_without_tools",
        label: "Badge without tools",
        icon: "hero-puzzle-piece",
        description: "A test module."
      }

    def enabled?, do: true
    def get_config, do: %{enabled: true}
  end

  setup %{conn: conn} do
    for mod <- [WithTools, WithoutTools], do: ModuleRegistry.register(mod)
    # The page lists external modules from the discovery cache; put these two in it.
    :persistent_term.put({ModuleDiscovery, :external_modules}, [WithTools, WithoutTools])

    on_exit(fn ->
      for mod <- [WithTools, WithoutTools], do: ModuleRegistry.unregister(mod)
      ModuleDiscovery.clear_cache()
    end)

    owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")
    %{conn: log_in_user(conn, owner)}
  end

  test "a module with tools shows API on, one without shows nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, @modules_path)

    assert has_element?(view, "#module-api-badge-badge_with_tools", "API on")
    refute has_element?(view, "#module-api-badge-badge_without_tools")
  end

  test "the badge links to the API settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, @modules_path)

    href = view |> element("#module-api-badge-badge_with_tools") |> render() |> href_of()
    assert href == Routes.path("/admin/settings/api") <> "#api-modules-card"
  end

  test "the badge follows the module's switch", %{conn: conn} do
    {:ok, _} = Settings.update_setting("api_disabled_modules", "badge_with_tools")

    {:ok, view, _html} = live(conn, @modules_path)

    assert has_element?(view, "#module-api-badge-badge_with_tools", "API off")
    refute has_element?(view, "#module-api-badge-badge_with_tools", "API on")
  end

  test "a person without the api permission sees the state but gets no link" do
    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "badge_with_tools")

    {:ok, view, _html} =
      Phoenix.ConnTest.build_conn() |> log_in_user(admin) |> live(@modules_path)

    assert has_element?(view, "span#module-api-badge-badge_with_tools", "API on")
    refute has_element?(view, "a#module-api-badge-badge_with_tools")
  end

  defp href_of(html) do
    [_, href] = Regex.run(~r/href="([^"]+)"/, html)
    href
  end
end
