defmodule PhoenixKit.Users.StartPagePreferenceTest do
  @moduledoc """
  The per-user "start on this page" preference.

  It rides in `custom_fields` under a reserved key, so the tests that matter
  are about what it refuses to store: a preference fired on every login is a
  redirect primitive, and an unvalidated one is an open redirect.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.Auth

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "start-page-#{System.unique_integer([:positive])}@example.com",
        password: "hello world!"
      })

    user
  end

  describe "update_user_start_page/2" do
    test "stores a relative path and reads it back" do
      user = user_fixture()

      assert {:ok, updated} = Auth.update_user_start_page(user, "/admin/projects")
      assert Auth.user_start_page(updated) == "/admin/projects"
    end

    test "nil clears it" do
      user = user_fixture()
      {:ok, set} = Auth.update_user_start_page(user, "/admin/projects")

      assert {:ok, cleared} = Auth.update_user_start_page(set, nil)
      assert Auth.user_start_page(cleared) == nil
    end

    test "an empty string clears it too" do
      user = user_fixture()
      {:ok, set} = Auth.update_user_start_page(user, "/admin/projects")

      assert {:ok, cleared} = Auth.update_user_start_page(set, "")
      assert Auth.user_start_page(cleared) == nil
    end

    test "refuses an absolute URL" do
      user = user_fixture()
      assert {:error, _} = Auth.update_user_start_page(user, "https://evil.test/steal")
    end

    test "refuses a protocol-relative path" do
      # `//evil.test` is a URL, not a path — the browser treats it as another
      # host. Stored, it would be an open redirect fired on every login.
      user = user_fixture()
      assert {:error, _} = Auth.update_user_start_page(user, "//evil.test")
      assert {:error, _} = Auth.update_user_start_page(user, "/\\evil.test")
    end

    test "refuses anything that is not a path at all" do
      user = user_fixture()
      assert {:error, _} = Auth.update_user_start_page(user, "admin/projects")
      assert {:error, _} = Auth.update_user_start_page(user, "javascript:alert(1)")
    end

    test "leaves other custom fields alone" do
      user = user_fixture()
      {:ok, user} = Auth.merge_user_custom_fields(user, %{"department" => "Kitchens"})

      {:ok, updated} = Auth.update_user_start_page(user, "/admin/projects")

      assert updated.custom_fields["department"] == "Kitchens"
      assert Auth.user_start_page(updated) == "/admin/projects"
    end

    test "clearing leaves other custom fields alone" do
      user = user_fixture()
      {:ok, user} = Auth.merge_user_custom_fields(user, %{"department" => "Kitchens"})
      {:ok, user} = Auth.update_user_start_page(user, "/admin/projects")

      {:ok, cleared} = Auth.update_user_start_page(user, nil)

      assert cleared.custom_fields["department"] == "Kitchens"
      assert Auth.user_start_page(cleared) == nil
    end
  end

  describe "user_start_page/1" do
    test "nil for a user who never set one, and for no user at all" do
      assert Auth.user_start_page(user_fixture()) == nil
      assert Auth.user_start_page(nil) == nil
    end

    test "nil for a blank stored value rather than an empty redirect" do
      user = user_fixture()
      {:ok, user} = Auth.merge_user_custom_fields(user, %{"start_page" => ""})

      assert Auth.user_start_page(user) == nil
    end
  end
end
