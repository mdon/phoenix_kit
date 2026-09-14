defmodule PhoenixKitWeb.Components.AnnotationComposerAttachmentsTest do
  @moduledoc """
  Unit tests for `AnnotationComposer.place_stored_file/3` — the host
  placement hook for annotation-comment attachments (plan 7, task 3).
  `@doc false` on the function, public only for this test.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.AnnotationComposer

  @file_uuid_placeholder "01900000-0000-7000-8000-000000000001"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  defp create_root_file!(user_uuid) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "annotation_#{n}.jpg",
        file_name: "annotation_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        # `file_checksum`/`user_file_checksum` are `NOT NULL` in V95.
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: nil,
        user_uuid: user_uuid
      })

    file
  end

  defp create_user! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        email: "annotation-composer-attachments-#{n}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp fake_socket(file_uuid), do: %{assigns: %{file_uuid: file_uuid}}

  # ---------------------------------------------------------------------------
  # Fake hooks
  # ---------------------------------------------------------------------------

  defmodule ReturningHook do
    @moduledoc false
    def parent_for(kind, actor_uuid, subject) do
      send(self(), {:hook_called, kind, actor_uuid, subject})
      Process.get(:annotation_composer_test_folder_uuid) |> then(&{:ok, &1})
    end
  end

  defmodule RaisingHook do
    @moduledoc false
    def parent_for(_kind, _actor_uuid, _subject), do: raise("boom")
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_comments, :attachments_parent_folder) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # place_stored_file/3
  # ---------------------------------------------------------------------------

  describe "place_stored_file/3" do
    test "hook configured: receives (:annotation_attachment, user_uuid, subject) and the file is attached to the returned folder" do
      user = create_user!()
      file = create_root_file!(user.uuid)
      folder = create_folder!()

      # ReturningHook reads this from the process dictionary so the test
      # process (which also runs the hook, since apply/3 stays synchronous)
      # can hand it the folder to return.
      Process.put(:annotation_composer_test_folder_uuid, folder.uuid)

      Application.put_env(
        :phoenix_kit_comments,
        :attachments_parent_folder,
        {ReturningHook, :parent_for}
      )

      assert :ok =
               AnnotationComposer.place_stored_file(
                 file,
                 fake_socket(@file_uuid_placeholder),
                 user.uuid
               )

      assert_received {:hook_called, :annotation_attachment, actor_uuid, subject}
      assert actor_uuid == user.uuid
      assert subject == %{resource_type: "file", resource_uuid: @file_uuid_placeholder}

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == folder.uuid
    end

    test "no hook configured: the file is left untouched" do
      user = create_user!()
      file = create_root_file!(user.uuid)

      assert :ok =
               AnnotationComposer.place_stored_file(
                 file,
                 fake_socket(@file_uuid_placeholder),
                 user.uuid
               )

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == nil
    end

    test "a raising hook returns :ok and leaves the file untouched" do
      user = create_user!()
      file = create_root_file!(user.uuid)

      Application.put_env(
        :phoenix_kit_comments,
        :attachments_parent_folder,
        {RaisingHook, :parent_for}
      )

      assert :ok =
               AnnotationComposer.place_stored_file(
                 file,
                 fake_socket(@file_uuid_placeholder),
                 user.uuid
               )

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == nil
    end
  end
end
