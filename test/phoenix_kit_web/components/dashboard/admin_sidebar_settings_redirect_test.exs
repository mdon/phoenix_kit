defmodule PhoenixKitWeb.Components.Dashboard.AdminSidebarSettingsRedirectTest do
  @moduledoc """
  Unit tests for issue #842: the Settings sidebar entry must land the
  visitor on a subtab they can actually open.

  `AdminTabs.settings_visible?/1` shows the Settings entry to any scope
  holding the core `"settings"` permission, `"media"`,
  `"integrations_system"`, OR any feature module's settings-subtab
  permission — `PhoenixKit.Modules.Sitemap` is a real, already-registered
  example, contributing a subtab under `:admin_settings` gated on
  `"sitemap"` (`lib/modules/sitemap/sitemap.ex`). Until this fix the entry's
  link pointed unconditionally at `/admin/settings` (General), gated on
  `"settings"` alone — a role holding only `"sitemap"` saw the entry, clicked
  it, and bounced.

  DB-free, following the pattern in `AdminSidebarReachabilityTest`: scopes are
  literal `%Scope{}` structs, and the tab set is `AdminTabs.settings_tabs/0`
  filtered the same way `PhoenixKit.Dashboard.Registry.get_tabs/1` would
  (`Tab.permission_granted?/2` then `Tab.visible?/2`) — the registry itself is
  not booted in core's unit environment.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Dashboard.{AdminTabs, Tab, TabHelpers}
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitWeb.Components.Dashboard.AdminSidebar

  defp scope(permissions) do
    %Scope{
      user: %User{uuid: "0193a5e4-0000-7000-8000-0000000000aa", email: "nav@example.com"},
      authenticated?: true,
      cached_roles: ["Editor"],
      cached_permissions: MapSet.new(permissions)
    }
  end

  # Mirrors the filtering `PhoenixKit.Dashboard.Registry.get_tabs/1` applies
  # for an :admin, scope-bound query — minus the level/enabled filters, which
  # are not what this issue is about and every tab here is already :admin.
  defp visible_settings_tabs(scope, extra_tabs \\ []) do
    (AdminTabs.settings_tabs() ++ extra_tabs)
    |> Enum.filter(&(Tab.permission_granted?(&1, scope) and Tab.visible?(&1, scope)))
    |> Enum.sort_by(& &1.priority)
  end

  # A module settings subtab registered BELOW General's priority — the shape
  # `phoenix_kit_bookings` ships (`:admin_settings_bookings`, priority 650).
  defp low_priority_module_subtab do
    Tab.resolve_path(
      %Tab{
        id: :admin_settings_bookings,
        label: "Bookings",
        icon: "hero-calendar",
        path: "settings/bookings",
        priority: 650,
        level: :admin,
        parent: :admin_settings,
        permission: "bookings"
      },
      :admin
    )
  end

  defp render_settings_entry(scope, current_path \\ "/admin/nowhere", extra_tabs \\ []) do
    tabs = visible_settings_tabs(scope, extra_tabs) |> TabHelpers.add_active_state(current_path)
    parent = Enum.find(tabs, &(&1.id == :admin_settings))

    render_component(&AdminSidebar.__tab_with_subtabs_for_test__/1,
      tab: parent,
      all_tabs: tabs,
      locale: nil
    )
  end

  # `TabItem.build_path/2` runs every rendered path through `Routes.path/2`,
  # which prepends the configured url_prefix and locale segment (test env
  # runs with both set) — so hrefs are never the bare tab path. Matches the
  # closing quote right after `path` so `/admin/settings` does not also
  # match `/admin/settings/sitemap`.
  defp href_exact?(html, path) do
    html =~ ~r{href="[^"]*#{Regex.escape(path)}"}
  end

  # The parent entry's own anchor (the one carrying `data-tab-id="admin_settings"`),
  # as opposed to the subtab links in the flyout.
  defp parent_href(html) do
    case Regex.run(~r{<a href="([^"]*)"[^>]*data-tab-id="admin_settings"}, html) do
      [_, href] -> href
      nil -> nil
    end
  end

  describe "a role holding only a module's settings-subtab permission" do
    test "the Settings entry is offered at all" do
      assert AdminTabs.settings_visible?(scope(["sitemap"]))
    end

    test "its link points at the module's subtab, not bare /admin/settings" do
      html = render_settings_entry(scope(["sitemap"]))

      assert href_exact?(html, "/admin/settings/sitemap")
      refute href_exact?(html, "/admin/settings")
    end
  end

  describe "a role holding no settings-related permission at all" do
    test "the Settings entry is not offered" do
      refute AdminTabs.settings_visible?(scope(["client_portal"]))
    end

    test "the parent tab does not survive the scope-filtered list" do
      tabs = visible_settings_tabs(scope(["client_portal"]))

      refute Enum.any?(tabs, &(&1.id == :admin_settings))
    end
  end

  describe "a role holding the core settings permission" do
    test "the link still points at General — no regression" do
      html = render_settings_entry(scope(["settings"]))

      assert href_exact?(html, "/admin/settings")
    end
  end

  describe "a role holding settings plus extra module permissions" do
    test "General (lowest priority) still wins the redirect" do
      html = render_settings_entry(scope(["settings", "sitemap", "media"]))

      assert href_exact?(html, "/admin/settings")
    end

    test "a module subtab with a priority below General does not hijack a settings holder's link" do
      html =
        render_settings_entry(scope(["settings", "bookings"]), "/admin/nowhere", [
          low_priority_module_subtab()
        ])

      assert parent_href(html) =~ ~r{/admin/settings$}
    end

    test "the same low-priority module subtab is the target when General is out of reach" do
      # `sitemap` keeps the parent entry visible (`settings_visible?/1` reads
      # module keys from the ModuleRegistry, which knows sitemap but not this
      # synthetic subtab); the redirect itself is decided among the reachable
      # subtabs, where bookings (650) sorts before sitemap (931).
      html =
        render_settings_entry(scope(["bookings", "sitemap"]), "/admin/nowhere", [
          low_priority_module_subtab()
        ])

      assert parent_href(html) =~ ~r{/admin/settings/bookings$}
    end
  end
end
