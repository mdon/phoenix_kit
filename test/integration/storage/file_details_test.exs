defmodule PhoenixKit.Integration.Storage.FileDetailsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth

  defp create_file!(metadata) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{email: "details_#{n}@example.com", password: "ValidPassword123!"})

    Repo.insert!(%StorageFile{
      original_file_name: "details_#{n}.jpg",
      file_name: "details_#{n}.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "sha256:details-#{n}",
      user_file_checksum: "user-sha256:details-#{n}",
      size: 1024,
      status: "active",
      metadata: metadata,
      user_uuid: user.uuid
    })
  end

  test "a new file has empty translations" do
    assert Repo.reload!(create_file!(nil)).data == %{}
  end

  test "saves the text and its translations, and reads them back per language" do
    file = create_file!(%{"rotation" => 90})

    data = %{
      "_primary_language" => "en-US",
      "en-US" => %{"_title" => "Harbour", "_alt" => "Boats in a harbour"},
      "et" => %{"_alt" => "Paadid sadamas"}
    }

    assert {:ok, updated} =
             Storage.update_file_details(file, %{
               "title" => "Harbour",
               "alt" => "Boats in a harbour",
               "data" => data
             })

    reloaded = Repo.reload!(updated)
    assert reloaded.metadata["rotation"] == 90
    assert reloaded.metadata["title"] == "Harbour"
    assert Storage.translated_alt(reloaded, "et") == "Paadid sadamas"
    assert Storage.translated_alt(reloaded, "en-US") == "Boats in a harbour"
    assert Storage.translated_title(reloaded, "et") == "Harbour"
  end

  test "merges into the row as it is now, not the struct it was handed" do
    stale = create_file!(%{"title" => "Old"})
    {:ok, _} = Storage.update_file(Repo.reload!(stale), %{metadata: %{"rotation" => 180}})

    assert {:ok, updated} = Storage.update_file_details(stale, %{"title" => "Harbour"})

    assert updated.metadata == %{
             "rotation" => 180,
             "title" => "Harbour",
             "alt" => "",
             "description" => ""
           }
  end

  test "an invalid save returns the form's changeset and writes nothing" do
    file = create_file!(%{"title" => "Harbour"})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Storage.update_file_details(file, %{"title" => String.duplicate("a", 256)})

    assert changeset.errors[:title]
    assert Repo.reload!(file).metadata == %{"title" => "Harbour"}
  end

  test "a file that is gone is :not_found" do
    file = create_file!(nil)
    Repo.delete!(file)

    assert Storage.update_file_details(file, %{"title" => "Harbour"}) == {:error, :not_found}
  end
end
