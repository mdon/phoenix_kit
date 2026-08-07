defmodule PhoenixKit.Integration.Users.OAuthEmailVerificationTest do
  @moduledoc """
  An OAuth callback must not attach an external identity to a pre-existing
  local account on email string equality alone: whoever gets an address onto a
  provider account then signs in as its owner. These tests pin the three
  resolution paths — existing link, existing local account, new account.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthProvider

  defp unique_email, do: "oauth_#{System.unique_integer([:positive])}@example.com"

  defp local_user(email) do
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    Repo.get!(Auth.User, user.uuid)
  end

  defp oauth_data(email, overrides \\ %{}) do
    Map.merge(
      %{
        provider: "google",
        provider_uid: "uid_#{System.unique_integer([:positive])}",
        email: email,
        first_name: "Test",
        last_name: "User",
        image: nil,
        access_token: "at",
        refresh_token: nil,
        token_expires_at: nil,
        raw_info: %{}
      },
      overrides
    )
  end

  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  describe "attaching to an existing local account" do
    test "is refused when the provider asserts nothing" do
      email = unique_email()
      _user = local_user(email)

      assert {:error, :provider_email_unverified} = OAuth.find_or_create_user(oauth_data(email))
    end

    test "is refused when the provider says the address is NOT verified" do
      email = unique_email()
      _user = local_user(email)

      data = oauth_data(email, %{raw_info: %{"user" => %{"email_verified" => false}}})

      assert {:error, :provider_email_unverified} = OAuth.find_or_create_user(data)
    end

    test "is allowed when the provider asserts email_verified, in the shape the strategies emit" do
      email = unique_email()
      user = local_user(email)

      # ueberauth_google/github/facebook all build
      # `raw_info: %{token: ..., user: ...}` with ATOM keys, and the payload
      # nested under `:user` is decoded JSON with STRING keys. A gate that reads
      # only `"user"` never fires on a real callback — this test is what pins
      # that down.
      data =
        oauth_data(email, %{
          raw_info: %{token: "tok", user: %{"email" => email, "email_verified" => true}}
        })

      assert {:ok, found, :found} = OAuth.find_or_create_user(data)
      assert found.uuid == user.uuid
    end

    test "accepts a string-keyed raw_info too, for providers that hand one over" do
      email = unique_email()
      _user = local_user(email)

      data = oauth_data(email, %{raw_info: %{"user" => %{"email_verified" => true}}})

      assert {:ok, _user, :found} = OAuth.find_or_create_user(data)
    end

    test "accepts the string spelling of the claim value providers sometimes send" do
      email = unique_email()
      _user = local_user(email)

      data = oauth_data(email, %{raw_info: %{user: %{"email_verified" => "true"}}})

      assert {:ok, _user, :found} = OAuth.find_or_create_user(data)
    end

    test "an OIDC provider that puts the claim at the top level of raw_info" do
      email = unique_email()
      _user = local_user(email)

      data = oauth_data(email, %{raw_info: %{email_verified: true}})

      assert {:ok, _user, :found} = OAuth.find_or_create_user(data)
    end

    test "GitHub: the verified flag must belong to THIS address" do
      email = unique_email()
      _user = local_user(email)

      matching =
        oauth_data(email, %{
          provider: "github",
          raw_info: %{user: %{"emails" => [%{"email" => email, "verified" => true}]}}
        })

      assert {:ok, _user, :found} = OAuth.find_or_create_user(matching)

      other_address =
        oauth_data(email, %{
          provider: "github",
          raw_info: %{
            user: %{
              "emails" => [
                %{"email" => "someone-else@example.com", "verified" => true},
                %{"email" => email, "verified" => false}
              ]
            }
          }
        })

      assert {:error, :provider_email_unverified} = OAuth.find_or_create_user(other_address)
    end

    test "a malformed raw_info is treated as no assertion, not as an error" do
      email = unique_email()
      _user = local_user(email)

      for raw <- [nil, "not a map", %{user: "not a map"}, %{"user" => "not a map"}, %{}] do
        data = oauth_data(email, %{raw_info: raw})
        assert {:error, :provider_email_unverified} = OAuth.find_or_create_user(data)
      end
    end
  end

  describe "an identity that is already linked" do
    test "signs in on the provider uid, without consulting the email at all" do
      email = unique_email()
      user = local_user(email)
      uid = "uid_#{System.unique_integer([:positive])}"

      {:ok, _} =
        %OAuthProvider{}
        |> OAuthProvider.changeset(%{
          user_uuid: user.uuid,
          provider: "google",
          provider_uid: uid,
          provider_email: email
        })
        |> Repo.insert()

      # No verification claim, and even a different address on the callback:
      # the link itself is the proof, so this must resolve to the linked user.
      data = oauth_data("different-#{email}", %{provider: "google", provider_uid: uid})

      assert {:ok, found, :found} = OAuth.find_or_create_user(data)
      assert found.uuid == user.uuid
    end
  end

  describe "a brand-new account" do
    test "is created, but is only auto-confirmed on a provider assertion" do
      unverified_email = unique_email()

      assert {:ok, created, :created} = OAuth.find_or_create_user(oauth_data(unverified_email))
      assert created.email == unverified_email
      refute created.confirmed_at, "an unvouched address must not arrive pre-confirmed"

      verified_email = unique_email()

      data = oauth_data(verified_email, %{raw_info: %{"user" => %{"email_verified" => true}}})

      assert {:ok, confirmed, :created} = OAuth.find_or_create_user(data)
      assert confirmed.confirmed_at
    end
  end
end
