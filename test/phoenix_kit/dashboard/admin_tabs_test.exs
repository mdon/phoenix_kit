defmodule PhoenixKit.Dashboard.AdminTabsTest do
  @moduledoc """
  Unit tests for the Send Profiles sidebar sub-item registered under
  Email Sending in `PhoenixKit.Dashboard.AdminTabs.settings_tabs/0`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.AdminTabs

  test "registers Send Profiles as its own sidebar tab nested under Email Sending" do
    tabs = AdminTabs.settings_tabs()

    email_sending = Enum.find(tabs, &(&1.id == :admin_settings_email_sending))
    send_profiles = Enum.find(tabs, &(&1.id == :admin_settings_send_profiles))

    assert email_sending
    assert send_profiles
    assert send_profiles.parent == email_sending.id
    assert send_profiles.path == "/admin/settings/email-sending/profiles"
    assert send_profiles.permission == email_sending.permission
    assert send_profiles.level == :admin
  end
end
