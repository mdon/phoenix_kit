defmodule PhoenixKit.Integration.Users.ProfileHiddenSectionsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKitWeb.Components.ProfileSettingsTabs

  setup do
    # The settings cache would otherwise hand back an earlier test's value.
    for section <- ProfileSettingsTabs.hideable_sections(),
        do: ProfileSettingsTabs.set_section_hidden(section, false)

    :ok
  end

  test "nothing is hidden by default, and the Google field shows" do
    assert ProfileSettingsTabs.hidden_sections() == []
    assert ProfileSettingsTabs.google_email_shown?()
    assert :password in ProfileSettingsTabs.sections("security")
  end

  test "a hidden section leaves its tab; a tab of hidden sections only is not offered" do
    :ok = ProfileSettingsTabs.set_section_hidden(:password, true)
    assert ProfileSettingsTabs.sections("security") == [:oauth]
    assert "security" in ProfileSettingsTabs.tab_ids(nil)

    :ok = ProfileSettingsTabs.set_section_hidden(:oauth, true)
    assert ProfileSettingsTabs.sections("security") == []
    refute "security" in ProfileSettingsTabs.tab_ids(nil)

    :ok = ProfileSettingsTabs.set_section_hidden(:password, false)
    assert ProfileSettingsTabs.sections("security") == [:password]
  end

  test "the Google field hides on its own; identity cannot be hidden" do
    :ok = ProfileSettingsTabs.set_section_hidden(:google_email, true)
    refute ProfileSettingsTabs.google_email_shown?()
    assert :identity in ProfileSettingsTabs.sections("account")

    assert {:error, :not_hideable} = ProfileSettingsTabs.set_section_hidden(:identity, true)
  end
end
