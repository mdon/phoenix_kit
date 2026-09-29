defmodule PhoenixKitWeb.Users.OAuthRegistrationGateTest do
  @moduledoc """
  `allow_registration: false` means no new accounts — through every door.

  The setting hid the Register link and closed the password and magic-link
  routes, and OAuth went on creating accounts: a Google account nobody here
  had seen before arrived at the callback, fell through to "no local account
  → register a new one", and was signed straight in. Registration was closed
  and yet an account appeared, which is the same shape as the magic-link
  completion hole ("a button hidden without the route being closed").

  Signing IN stays open, because that is what the setting is about: an
  existing account reached by its provider link, or by a verified email that
  already has an account here, still gets in.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, OAuth}

  setup do
    # Registration is open by default; every test here closes it and puts it
    # back, since the setting is global and the suite shares a database.
    on_exit(fn -> Settings.update_setting("allow_registration", "true") end)
    :ok
  end

  defp oauth_data(email, opts \\ []) do
    %{
      provider: "google",
      provider_uid: Keyword.get(opts, :uid, "uid-#{System.unique_integer([:positive])}"),
      email: email,
      first_name: "Test",
      last_name: "Person",
      image: nil,
      access_token: "token",
      refresh_token: nil,
      token_expires_at: nil,
      # Google asserts it verified the address; without this the takeover
      # branch refuses regardless of the registration setting.
      raw_info: %{user: %{"email_verified" => true}}
    }
  end

  defp unique_email, do: "oauth-gate-#{System.unique_integer([:positive])}@example.com"

  describe "with registration closed" do
    test "an unknown provider account is refused instead of registered" do
      Settings.update_setting("allow_registration", "false")
      email = unique_email()

      assert {:error, :registration_disabled} = OAuth.find_or_create_user(oauth_data(email))

      refute Auth.get_user_by_email(email),
             "a closed registration must not leave a new account behind"
    end

    test "an account that already exists here still signs in" do
      # The setting closes the door to NEW accounts. Someone who already has
      # one keeps using their provider to get in.
      email = unique_email()

      {:ok, user} =
        Auth.register_user(%{"email" => email, "password" => "ValidPassword123!"})

      Settings.update_setting("allow_registration", "false")

      assert {:ok, found, :found} = OAuth.find_or_create_user(oauth_data(email))
      assert found.uuid == user.uuid
    end

    test "and so does one whose provider is already linked" do
      email = unique_email()
      data = oauth_data(email)

      {:ok, user, :created} = OAuth.find_or_create_user(data)
      {:ok, _} = OAuth.link_oauth_provider(user, data)

      Settings.update_setting("allow_registration", "false")

      assert {:ok, _user, :found} = OAuth.find_or_create_user(data)
    end
  end

  describe "with registration open" do
    test "an unknown provider account is registered, as before" do
      email = unique_email()

      assert {:ok, user, :created} = OAuth.find_or_create_user(oauth_data(email))
      assert user.email == email
    end
  end
end
