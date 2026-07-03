defmodule PhoenixKitWeb.Users.AuthSeoNoIndexTest do
  @moduledoc """
  Regression test for `seo_no_index` not reaching a host application's own
  public LiveViews. `PhoenixKitWeb.Components.LayoutWrapper.app_layout_inner/1`
  is the only place that used to assign `:seo_no_index` — but it only wraps
  PhoenixKit's own admin/plugin views. A host app's public LiveView (its own
  layout, not routed through LayoutWrapper) never got the assign, so
  `root.html.heex`'s `<meta name="robots" content="noindex,nofollow">` never
  rendered for it even with the directive enabled (observed on Hydroforce's
  dev environment).

  `PublicHostAppLive` below stands in for such a view: it mounts through
  PhoenixKit's `:phoenix_kit_mount_current_scope` on_mount (as a host app
  would, e.g. for current_user/locale support) but renders with its own
  markup, never calling `LayoutWrapper.app_layout`.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.SEO

  defmodule PublicHostAppLive do
    @moduledoc false
    use Phoenix.LiveView

    on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}

    @impl true
    def render(assigns) do
      ~H"""
      <div id="seo-no-index-probe" data-seo-no-index={inspect(assigns[:seo_no_index])}></div>
      """
    end
  end

  setup do
    on_exit(fn -> SEO.update_no_index(false) end)
    :ok
  end

  test "a public host-app LiveView going through PhoenixKit's on_mount gets :seo_no_index=true when the directive is enabled",
       %{conn: conn} do
    {:ok, _} = SEO.enable_no_index()

    {:ok, _view, html} = live_isolated(conn, PublicHostAppLive, session: %{})

    assert html =~ ~s(data-seo-no-index="true")
  end

  test "a public host-app LiveView gets :seo_no_index=false when the directive is disabled",
       %{conn: conn} do
    {:ok, _} = SEO.update_no_index(false)

    {:ok, _view, html} = live_isolated(conn, PublicHostAppLive, session: %{})

    assert html =~ ~s(data-seo-no-index="false")
  end
end
