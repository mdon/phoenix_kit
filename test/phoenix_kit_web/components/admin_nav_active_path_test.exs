defmodule PhoenixKitWeb.Components.AdminNavActivePathTest do
  @moduledoc """
  Active-state matching is about the PATH. A module that publishes its full URL
  into `:url_path` — so the language switcher can rebuild locale links without
  dropping state — hands the sidebar a `current_path` with a query or a
  fragment attached. `PhoenixKit.Dashboard.Tab.normalize_path/1` strips both;
  this pins the same for the nav's own matcher, which previously stripped only
  the query.

  DB-free: `admin_nav_item/1` is a plain function component.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Components.AdminNav

  @active "bg-primary text-primary-content"

  defp render(current_path, href \\ "/admin/users") do
    render_component(&AdminNav.admin_nav_item/1,
      href: href,
      icon: "users",
      label: "Users",
      current_path: current_path
    )
  end

  test "the bare path is active" do
    assert render("/admin/users") =~ @active
  end

  test "a query string does not lose the active state" do
    assert render("/admin/users?filter=active") =~ @active
  end

  test "a fragment does not lose the active state" do
    assert render("/admin/users#roles") =~ @active
    assert render("/admin/users?filter=active#roles") =~ @active
  end

  test "a different section stays inactive whatever it carries" do
    refute render("/admin/settings#roles") =~ @active
    refute render("/admin/settings?path=/admin/users") =~ @active
  end

  test "a fragment on a ?tab= path does not corrupt the tab it matches" do
    # `?tab=` is part of the match, so the fragment has to come off the VALUE
    # too — "files#top" is not the tab "files".
    href = "/admin/users?tab=files"

    assert render("/admin/users?tab=files#top", href) =~ @active
    refute render("/admin/users?tab=roles#top", href) =~ @active
  end
end
