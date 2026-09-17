defmodule PhoenixKit.Users.GoogleEmailTest do
  @moduledoc """
  `google_email` is where we SHARE with a user through Google, not an
  identity: optional, not unique, nothing authenticates against it. These
  pin the changeset's normalisation and `Auth.google_email/1`'s fallback —
  the fallback being the reason a user who signed up with a Gmail address
  never has to type it a second time.
  """
  # DataCase, not bare ExUnit.Case: profile_changeset/3's validate_email/2
  # runs an unsafe_validate_unique, which needs a sandbox checkout.
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  defp errors_on_field(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end

  defp user(attrs \\ %{}), do: struct(%User{email: "person@example.com"}, attrs)

  describe "profile_changeset/3" do
    test "accepts an address and stores it downcased and trimmed" do
      changeset = User.profile_changeset(user(), %{"google_email" => "  Work@Example.COM "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :google_email) == "work@example.com"
    end

    test "a cleared input becomes nil, so 'unset' has one representation" do
      changeset =
        user(%{google_email: "old@example.com"})
        |> User.profile_changeset(%{"google_email" => "   "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :google_email) == nil
    end

    test "rejects an address with no @ or with spaces" do
      for bad <- ["not-an-address", "two words@example.com"] do
        changeset = User.profile_changeset(user(), %{"google_email" => bad})

        refute changeset.valid?
        assert "must have the @ sign and no spaces" in errors_on_field(changeset, :google_email)
      end
    end

    test "rejects an address past the column width" do
      long = String.duplicate("a", 155) <> "@example.com"
      changeset = User.profile_changeset(user(), %{"google_email" => long})

      refute changeset.valid?
      assert errors_on_field(changeset, :google_email) != []
    end

    test "is not required, and two users may share one address" do
      assert User.profile_changeset(user(), %{}).valid?

      {:ok, first} =
        Auth.register_user(%{
          email: "first_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!",
          google_email: "shared@example.com"
        })

      assert first.google_email == "shared@example.com"

      {:ok, second} =
        Auth.register_user(%{
          email: "second_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!",
          google_email: "shared@example.com"
        })

      assert second.google_email == "shared@example.com"
    end
  end

  describe "google_email/1" do
    test "prefers the stored address over the sign-in one" do
      assert Auth.google_email(user(%{google_email: "work@example.com"})) == "work@example.com"
    end

    test "falls back to a Google-hosted sign-in address" do
      assert Auth.google_email(user(%{email: "person@gmail.com"})) == "person@gmail.com"
      assert Auth.google_email(user(%{email: "Person@GoogleMail.com"})) == "person@googlemail.com"
    end

    test "guesses nothing from an address that may have no Google account behind it" do
      # A share sent to an address with no Google account is a share the user
      # never receives, so the honest answer here is "we don't know".
      assert Auth.google_email(user(%{email: "person@example.com"})) == nil
      assert Auth.google_email(user(%{email: "person@notgmail.com"})) == nil
    end

    test "treats a blank stored address as unset" do
      assert Auth.google_email(user(%{google_email: "  ", email: "person@gmail.com"})) ==
               "person@gmail.com"

      assert Auth.google_email(user(%{google_email: "", email: "person@example.com"})) == nil
    end
  end
end
