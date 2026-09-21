defmodule PhoenixKit.Dashboard.AdminSettingsEntryRedirectTest do
  @moduledoc """
  Unit tests for issue #842.

  The Settings sidebar entry is visible (`AdminTabs.settings_visible?/1`) to
  any scope holding the core `"settings"` permission, `"media"`,
  `"integrations_system"`, OR any feature module's settings-subtab
  permission — but until this fix its link pointed unconditionally at
  `/admin/settings` (the General subtab), which is gated by `"settings"`
  alone. A role holding only a module settings permission could see the
  entry, click it, and bounce.

  The fix reuses the existing, already-documented
  `redirect_to_first_subtab: true` mechanism
  (`PhoenixKit.Dashboard.Tab`, `PhoenixKitWeb.Components.Dashboard.AdminSidebar.maybe_redirect_to_first_subtab/2`)
  on the `:admin_settings` parent tab, so its link follows whichever subtab
  sorts first by priority among the ones the registry has already filtered
  down to for the current scope.

  These tests cover the static shape (parent flag, subtab priority
  ordering); the scope-dependent redirect itself is covered at the
  component layer in
  `PhoenixKitWeb.Components.Dashboard.AdminSidebarSettingsRedirectTest`.
  `settings_visible?/1` and `settings_tab_permissions/0` are deliberately
  untouched by this fix and are not re-tested here.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.AdminTabs

  test "the Settings parent tab is flagged to redirect to its first visible subtab" do
    tabs = AdminTabs.settings_tabs()
    parent = Enum.find(tabs, &(&1.id == :admin_settings))

    assert parent
    assert parent.redirect_to_first_subtab == true
  end

  test "General is still the lowest-priority (first) subtab, so an unchanged scope redirects nowhere new" do
    tabs = AdminTabs.settings_tabs()
    general = Enum.find(tabs, &(&1.id == :admin_settings_general))

    subtab_priorities =
      tabs
      |> Enum.filter(&(&1.parent == :admin_settings))
      |> Enum.map(& &1.priority)

    assert general
    assert general.priority == Enum.min(subtab_priorities)
    assert general.path == "/admin/settings"
  end
end
