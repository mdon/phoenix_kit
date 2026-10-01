defmodule PhoenixKit.Integration.Users.ProfileHiddenSectionsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
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

  test "a toggle is attributed to the admin, and readers see it at once" do
    import Ecto.Query

    {:ok, user} =
      Auth.register_user(%{
        "email" => "sections-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    # Prime the cache with the old value, as a user page would.
    assert ProfileSettingsTabs.hidden_sections() == []

    :ok =
      ProfileSettingsTabs.set_section_hidden(:sessions, true,
        actor_uuid: user.uuid,
        source: "settings"
      )

    assert ProfileSettingsTabs.hidden_sections() == [:sessions]

    entry =
      RepoHelper.repo().one(
        from(e in Entry,
          where:
            e.action == "setting.changed" and
              fragment("? ->> 'key' = ?", e.metadata, "user_settings_hidden_sections") and
              e.actor_uuid == ^user.uuid,
          limit: 1
        )
      )

    assert entry
    assert entry.metadata["source"] == "settings"
  end
end
