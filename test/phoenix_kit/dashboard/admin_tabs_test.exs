defmodule PhoenixKit.Dashboard.AdminTabsTest do
  @moduledoc """
  Unit tests for the "Emails Bulk" (Send Profiles) sidebar tab registered
  as a top-level sibling of "Emails Transactional" in
  `PhoenixKit.Dashboard.AdminTabs.settings_tabs/0`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.AdminTabs

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
end
