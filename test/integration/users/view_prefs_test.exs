defmodule PhoenixKit.Integration.Users.ViewPrefsTest do
  @moduledoc """
  A user's preferences per view: fields are patched in the upsert, so a
  write never rebuilds the object from a stale copy, and reset takes a
  field back out.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.ViewPrefs

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "view-prefs-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  test "a user with no preferences reads an empty map" do
    assert ViewPrefs.get(user!(), "users") == %{}
    assert ViewPrefs.get(nil, "users") == %{}
    assert ViewPrefs.get(Ecto.UUID.generate(), "users") == %{}
  end

  test "put patches only the fields it is given" do
    user = user!()

    assert {:ok, %{"columns" => ["a", "b"]}} =
             ViewPrefs.put(user, "users", %{"columns" => ["a", "b"]})

    assert {:ok, prefs} = ViewPrefs.put(user.uuid, "users", %{"sort_by" => "name"})
    assert prefs == %{"columns" => ["a", "b"], "sort_by" => "name"}

    # A field is written whole — a list is replaced, not merged.
    assert {:ok, %{"columns" => ["c"]}} = ViewPrefs.put(user, "users", %{"columns" => ["c"]})
    assert ViewPrefs.get(user, "users") == %{"columns" => ["c"], "sort_by" => "name"}
  end

  test "views and users are kept apart" do
    [a, b] = [user!(), user!()]
    {:ok, _} = ViewPrefs.put(a, "users", %{"columns" => ["x"]})
    {:ok, _} = ViewPrefs.put(a, "catalogue.detail_items", %{"columns" => ["y"]})

    assert ViewPrefs.get(a, "users") == %{"columns" => ["x"]}
    assert ViewPrefs.get(a, "catalogue.detail_items") == %{"columns" => ["y"]}
    assert ViewPrefs.get(b, "users") == %{}
  end

  test "delete_fields takes fields back out, and delete_key clears a view" do
    user = user!()
    {:ok, _} = ViewPrefs.put(user, "users", %{"columns" => ["a"], "sort_by" => "name"})

    assert ViewPrefs.delete_fields(user, "users", ["columns"]) == {:ok, %{"sort_by" => "name"}}
    assert ViewPrefs.delete_fields(user!(), "users", ["columns"]) == {:ok, %{}}

    assert ViewPrefs.delete_key("users") == :ok
    assert ViewPrefs.get(user, "users") == %{}
  end

  test "writes refuse no user, a bad key and an oversized or malformed object" do
    user = user!()

    assert ViewPrefs.put(nil, "users", %{"columns" => []}) == {:error, :no_user}
    assert ViewPrefs.put("not-a-uuid", "users", %{}) == {:error, :no_user}
    assert ViewPrefs.put(Ecto.UUID.generate(), "users", %{"columns" => []}) == {:error, :no_user}
    assert ViewPrefs.put(user, "", %{}) == {:error, :invalid_key}
    assert ViewPrefs.put(user, String.duplicate("k", 256), %{}) == {:error, :invalid_key}
    assert ViewPrefs.put(user, "users", %{columns: []}) == {:error, :invalid_fields}
    assert ViewPrefs.put(user, "users", %{"x" => {:tuple}}) == {:error, :invalid_fields}

    assert ViewPrefs.put(user, "users", %{"filters" => String.duplicate("x", 20_000)}) ==
             {:error, :too_large}

    # A shape the guards cannot match is answered too, never raised.
    assert ViewPrefs.put(user, "users", "columns") == {:error, :invalid_arguments}
    assert ViewPrefs.delete_fields(user, "users", "columns") == {:error, :invalid_arguments}

    assert ViewPrefs.get(user, "users") == %{}
  end

  test "deleting the user deletes their preferences" do
    user = user!()
    {:ok, _} = ViewPrefs.put(user, "users", %{"columns" => ["a"]})

    Repo.delete!(user)

    assert Repo.aggregate(
             from(p in PhoenixKit.Users.ViewPref, where: p.user_uuid == ^user.uuid),
             :count
           ) == 0
  end
end
