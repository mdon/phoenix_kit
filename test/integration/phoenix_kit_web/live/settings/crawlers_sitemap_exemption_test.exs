defmodule PhoenixKitWeb.Live.Settings.CrawlersSitemapExemptionTest do
  @moduledoc """
  Pins the `toggle_sitemap_exempt_from_no_index` event handler on the
  Crawlers admin LiveView (`/admin/settings/crawlers`) — the checkbox that
  lets an operator keep the sitemap's content exempt from the global
  `crawlers_no_index` directive without touching the noindex meta tag.

  See `PhoenixKit.Modules.Crawlers.sitemap_exempt_from_no_index?/0` and
  `PhoenixKit.Integration.Sitemap.NoIndexTest` for the generator-level
  contract this UI toggle drives.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/crawlers")

  setup do
    {:ok, _} = Crawlers.enable_module()
    on_exit(fn -> Crawlers.disable_module() end)
    :ok
  end

  defp login(conn) do
    {user, _token} = create_admin_user()

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
    |> log_in_user(user)
  end

  describe "toggle_sitemap_exempt_from_no_index event" do
    test "renders the toggle as unchecked by default", %{conn: conn} do
      conn = login(conn)
      {:ok, view, _html} = live(conn, @path)
      refute toggle_checked?(view)
    end

    test "clicking the toggle persists ON and re-renders checked", %{conn: conn} do
      conn = login(conn)
      {:ok, view, _html} = live(conn, @path)

      refute Crawlers.sitemap_exempt_from_no_index?()

      view
      |> element("input[phx-click='toggle_sitemap_exempt_from_no_index']")
      |> render_click()

      assert Crawlers.sitemap_exempt_from_no_index?()
      assert toggle_checked?(view)
    end

    test "clicking again toggles OFF", %{conn: conn} do
      {:ok, _} = Crawlers.update_sitemap_exempt_from_no_index(true)
      conn = login(conn)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("input[phx-click='toggle_sitemap_exempt_from_no_index']")
      |> render_click()

      refute Crawlers.sitemap_exempt_from_no_index?()
      refute toggle_checked?(view)
    end

    test "mount reflects the persisted state", %{conn: conn} do
      {:ok, _} = Crawlers.update_sitemap_exempt_from_no_index(true)
      conn = login(conn)
      {:ok, view, _html} = live(conn, @path)

      assert toggle_checked?(view)
    end

    test "does not change the noindex directive itself", %{conn: conn} do
      conn = login(conn)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("input[phx-click='toggle_sitemap_exempt_from_no_index']")
      |> render_click()

      refute Crawlers.no_index_enabled?()
    end
  end

  # Same rationale as PhoenixKitWeb.Live.Modules.LanguagesToggleTest's helper:
  # Phoenix renders `checked={true}` with surrounding whitespace, so a plain
  # substring match is fragile. Isolate the toggle's outerHTML and check for
  # the `checked` attribute via regex.
  defp toggle_checked?(view) do
    selector = "input[phx-click='toggle_sitemap_exempt_from_no_index']"
    html = view |> element(selector) |> render()

    Regex.match?(~r/<input\b[^>]*\bchecked\b[^>]*>/, html)
  end
end
