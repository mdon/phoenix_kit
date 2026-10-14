defmodule PhoenixKit.Dashboard.AdminTabsTest do
  @moduledoc """
  Unit tests for sidebar tabs registered in
  `PhoenixKit.Dashboard.AdminTabs.settings_tabs/0`: the "Emails Bulk" (Send
  Profiles) tab and the "API" tab, plus who sees the Settings entry.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.AdminTabs
  alias PhoenixKit.Users.Auth.Scope

  defp scope_with(keys),
    do: %Scope{authenticated?: true, cached_permissions: MapSet.new(keys)}

  test "registers Emails Bulk as its own top-level sidebar tab, a sibling of Emails Transactional" do
    tabs = AdminTabs.settings_tabs()

    email_sending = Enum.find(tabs, &(&1.id == :admin_settings_email_sending))
    emails_bulk = Enum.find(tabs, &(&1.id == :admin_settings_emails_bulk))

    assert email_sending
    assert emails_bulk
    assert emails_bulk.parent == email_sending.parent
    assert emails_bulk.path == "/admin/settings/emails-bulk"
    assert emails_bulk.permission == email_sending.permission
    assert emails_bulk.level == :admin
  end

  describe "the API tab" do
    test "is a Settings subtab gated by the api permission" do
      api = Enum.find(AdminTabs.settings_tabs(), &(&1.id == :admin_settings_api))

      assert api
      assert api.parent == :admin_settings
      assert api.path == "/admin/settings/api"
      assert api.permission == "api"
      assert api.level == :admin
      assert api.priority == 921
      assert api.icon == "hero-key"
    end

    test "the Settings entry shows for a role holding only api" do
      assert AdminTabs.settings_visible?(scope_with(["api"]))
      assert AdminTabs.api_visible?(scope_with(["api"]))
    end

    test "the Settings entry stays hidden for a role without settings, integrations or api" do
      refute AdminTabs.settings_visible?(scope_with(["dashboard", "users"]))
      refute AdminTabs.api_visible?(scope_with(["dashboard", "users"]))
    end

    test "api_visible?/1 does not raise for a missing scope" do
      refute AdminTabs.api_visible?(nil)
    end
  end
end
