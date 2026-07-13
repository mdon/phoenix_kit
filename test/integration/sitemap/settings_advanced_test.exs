defmodule PhoenixKit.Integration.Sitemap.SettingsAdvancedTest do
  @moduledoc """
  Covers the sitemap settings page's "Advanced" section: four core settings
  that previously had no UI at all and could only be changed by editing the
  database directly — `sitemap_router_discovery_exclude_patterns`,
  `sitemap_protected_pipelines`, `sitemap_custom_urls`, `sitemap_static_routes`.

  Exercises the actual LiveView (mount + form submit), so it needs a
  database — uses `PhoenixKitWeb.ConnCase`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/sitemap")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "Router Discovery exclude patterns" do
    setup :setup_admin

    test "rejects an invalid regex pattern and does not save it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("form[phx-submit='save_exclude_patterns']", %{"patterns" => "^/admin\n*"})
        |> render_submit()

      assert html =~ "Invalid regex pattern"
      assert Settings.get_setting("sitemap_router_discovery_exclude_patterns") == nil
    end

    test "saves a valid list of patterns as a JSON array", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("form[phx-submit='save_exclude_patterns']", %{"patterns" => "^/admin\n^/api"})
      |> render_submit()

      assert Settings.get_setting("sitemap_router_discovery_exclude_patterns") ==
               JSON.encode!(["^/admin", "^/api"])
    end
  end

  describe "Protected pipelines" do
    setup :setup_admin

    test "rejects a pipeline name with invalid characters and does not save it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("form[phx-submit='save_protected_pipelines']", %{"pipelines" => "my pipeline"})
        |> render_submit()

      assert html =~ "Invalid pipeline name"
      assert Settings.get_setting("sitemap_protected_pipelines") == nil
    end

    test "saves a valid list of pipeline names as a JSON array", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("form[phx-submit='save_protected_pipelines']", %{
        "pipelines" => "member_only\napi_key"
      })
      |> render_submit()

      assert Settings.get_setting("sitemap_protected_pipelines") ==
               JSON.encode!(["member_only", "api_key"])
    end
  end

  describe "Custom URLs" do
    setup :setup_admin

    test "rejects invalid JSON and does not save it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("form[phx-submit='save_custom_urls']", %{"json" => "not json"})
        |> render_submit()

      assert html =~ "Invalid JSON"
      assert Settings.get_setting("sitemap_custom_urls") == nil
    end

    test "rejects a JSON value that isn't an array of objects", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("form[phx-submit='save_custom_urls']", %{"json" => ~s(["a", "b"])})
        |> render_submit()

      assert html =~ "Must be a JSON array of objects"
      assert Settings.get_setting("sitemap_custom_urls") == nil
    end

    test "saves a valid array of URL objects", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      json = JSON.encode!([%{"path" => "/about-us", "title" => "About Us"}])

      view
      |> form("form[phx-submit='save_custom_urls']", %{"json" => json})
      |> render_submit()

      assert {:ok, [%{"path" => "/about-us"}]} =
               "sitemap_custom_urls" |> Settings.get_setting() |> JSON.decode()
    end
  end

  describe "Static routes" do
    setup :setup_admin

    test "rejects invalid JSON and does not save it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("form[phx-submit='save_static_routes']", %{"json" => "{not json"})
        |> render_submit()

      assert html =~ "Invalid JSON"
      assert Settings.get_setting("sitemap_static_routes") == nil
    end

    test "saves a valid array of route objects", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      json = JSON.encode!([%{"path" => "/", "title" => "Home"}])

      view
      |> form("form[phx-submit='save_static_routes']", %{"json" => json})
      |> render_submit()

      assert {:ok, [%{"path" => "/"}]} =
               "sitemap_static_routes" |> Settings.get_setting() |> JSON.decode()
    end
  end
end
