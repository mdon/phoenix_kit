defmodule PhoenixKit.Integration.Users.OAuthGoogleEmailTest do
  @moduledoc """
  A Google sign-in proves the address we would share with, so the callback
  fills `google_email` from it — but only while the field is empty. A value
  someone typed is their own answer to "where do we share with you", and a
  second Google account signing in must not silently redirect their shares.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.OAuth

  defp unique_email, do: "goog_#{System.unique_integer([:positive])}@example.com"

  defp auth_struct(email, provider \\ :google) do
    %Ueberauth.Auth{
      provider: provider,
      uid: "uid_#{System.unique_integer([:positive])}",
      info: %Ueberauth.Auth.Info{
        email: email,
        first_name: "Test",
        last_name: "User",
        image: nil
      },
      credentials: %Ueberauth.Auth.Credentials{token: "at"},
      # The verified claim, in the shape the real strategies emit — without
      # it a callback for an address with an existing local account is
      # refused before it ever reaches the prefill.
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{token: "tok", user: %{"email" => email, "email_verified" => true}}
      }
    }
  end

  defp reload(user), do: Repo.get!(Auth.User, user.uuid)

  test "a Google sign-in fills the empty field from the provider address" do
    email = unique_email()

    assert {:ok, user} = OAuth.handle_oauth_callback(auth_struct(email))
    assert user.google_email == email
    assert reload(user).google_email == email
  end

  test "an address already on the record is left alone" do
    email = unique_email()

    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(user)
    {:ok, user} = Auth.update_user_profile(user, %{google_email: "typed@example.com"})

    assert {:ok, _} = OAuth.handle_oauth_callback(auth_struct(email))
    assert reload(user).google_email == "typed@example.com"
  end

  test "another provider's sign-in never fills it" do
    email = unique_email()

    assert {:ok, user} = OAuth.handle_oauth_callback(auth_struct(email, :github))
    assert reload(user).google_email == nil
  end

  test "the resolver prefers the filled value over a Gmail sign-in address" do
    email = "gmail_#{System.unique_integer([:positive])}@gmail.com"

    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    assert Auth.google_email(user) == email

    {:ok, user} = Auth.update_user_profile(user, %{google_email: "work@example.com"})
    assert Auth.google_email(user) == "work@example.com"
  end
end
