defmodule PhoenixKitWeb.Live.Modules.Storage.SettingsTabsTest do
  @moduledoc """
  Tabs on the Media settings page (`/admin/settings/media`) — Buckets /
  Configuration / Tools / External libraries, the same `<.nav_tabs>` treatment the Email
  Sending and Sitemap settings pages already have.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.System.Dependencies
  alias PhoenixKit.Utils.Routes

  @media_settings_path Routes.path("/admin/settings/media")

  defp admin_conn(conn) do
    {user, _token} = create_admin_user()
    log_in_user(conn, user)
  end

  # `class={cond && "hidden"}` drops the `class` attribute entirely when
  # `cond` is false (Phoenix omits `nil`/`false` attribute values rather than
  # rendering `class=""`), so a bare `find/2` on the wrapper's stable id tells
  # visible from hidden.
  defp tab_visible?(html, dom_id) do
    case html |> Floki.parse_document!() |> Floki.find("##{dom_id}") do
      [el] -> "hidden" not in String.split(Floki.attribute(el, "class") |> List.first() || "")
      [] -> flunk("no element with id=#{dom_id} found")
    end
  end

  test "the tabs render, defaulting to Buckets", %{conn: conn} do
    {:ok, _view, html} = live(admin_conn(conn), @media_settings_path)

    assert html =~ "Buckets"
    assert html =~ "Configuration"
    assert html =~ "Tools"
    assert html =~ "External libraries"
    refute html =~ "Quick Actions"
    refute html =~ "Media System Architecture"

    assert tab_visible?(html, "media-tab-buckets")
    refute tab_visible?(html, "media-tab-configuration")
    refute tab_visible?(html, "media-tab-tools")
  end

  test "switching to Configuration reveals it and hides the others", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("button[phx-value-tab=configuration]")
      |> render_click()

    refute tab_visible?(html, "media-tab-buckets")
    assert tab_visible?(html, "media-tab-configuration")
    refute tab_visible?(html, "media-tab-tools")
    assert html =~ "Redundancy Copies"
  end

  test "switching to Tools reveals its action buttons", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("button[phx-value-tab=tools]")
      |> render_click()

    refute tab_visible?(html, "media-tab-buckets")
    refute tab_visible?(html, "media-tab-configuration")
    assert tab_visible?(html, "media-tab-tools")
    assert html =~ "Variant sets"
    assert html =~ "Repair Media Module"
  end

  test "External libraries lists every tool with its status", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("button[role=tab][phx-value-tab=external_libraries]")
      |> render_click()

    assert tab_visible?(html, "media-tab-external-libraries")

    for tool <- Dependencies.external_tools() do
      assert html =~ tool.name
    end

    refute html =~ "brew install"
    assert view |> element("button[phx-click=recheck_external_tools]") |> render_click()
  end

  test "the missing-tools warning is not tab-scoped", %{conn: conn} do
    {:ok, view, html} = live(admin_conn(conn), @media_settings_path)

    # Whatever the dependency status is on this machine, switching tabs must
    # not change whether the warning shows — it lives above the tab strip.
    before_tools = html =~ "Not found on this server"

    html_after =
      view
      |> element("button[phx-value-tab=tools]")
      |> render_click()

    assert html_after =~ "Not found on this server" == before_tools
  end
end
