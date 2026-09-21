defmodule PhoenixKit.Integration.Storage.TrashBroadcastTest do
  @moduledoc """
  Trashing, restoring, and permanently deleting a file (or a folder's whole
  subtree) must broadcast on the files topic so an open MediaBrowser reacts
  live instead of keeping a stale card (issue #841).
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs) do
    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp create_file!(folder_uuid) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "test_#{n}.jpg",
        file_name: "test_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid,
        user_uuid: ensure_user!()
      })

    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "trash-broadcast-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  setup do
    Storage.subscribe_to_file_events()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Single-file operations
  # ---------------------------------------------------------------------------

  describe "trash_file/1" do
    test "broadcasts :phoenix_kit_file_trashed and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid

      assert {:ok, updated} = Storage.trash_file(file)
      assert updated.status == "trashed"
      # Pinned, not a bare capture: this subscribes to the GLOBAL files
      # topic with no per-test scoping, and other async test files trash
      # files of their own during the same run — an unpinned capture can
      # match a stranger's broadcast instead of this test's own.
      assert_receive {:phoenix_kit_file_trashed, ^file_uuid}
    end
  end

  describe "restore_file/1" do
    test "broadcasts :phoenix_kit_file_restored and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid
      {:ok, file} = Storage.trash_file(file)
      assert_receive {:phoenix_kit_file_trashed, ^file_uuid}

      assert {:ok, updated} = Storage.restore_file(file)
      assert updated.status == "active"
      assert_receive {:phoenix_kit_file_restored, ^file_uuid}
    end
  end

  describe "delete_file_completely/1" do
    test "broadcasts :phoenix_kit_file_deleted and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid

      assert {:ok, deleted} = Storage.delete_file_completely(file)
      assert_receive {:phoenix_kit_file_deleted, ^file_uuid}
      assert deleted.uuid == file_uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Folder-level sweep — do_trash_folder/do_restore_folder move files in bulk
  # via update_all, bypassing trash_file/restore_file entirely. Each swept
  # file still needs its own broadcast, or a page showing one of those files
  # (not the folder itself) never hears about it.
  # ---------------------------------------------------------------------------

  describe "trash_folder/2" do
    test "broadcasts :phoenix_kit_file_trashed for every file in the subtree" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})

      child =
        create_folder!(%{
          name: "child_#{System.unique_integer([:positive])}",
          parent_uuid: root.uuid
        })

      file_a = create_file!(root.uuid)
      file_b = create_file!(child.uuid)
      uuid_a = file_a.uuid
      uuid_b = file_b.uuid

      assert {:ok, _} = Storage.trash_folder(root)

      # Pinned to this test's own two uuids (see the comment on the
      # `trash_file/1` test above) — each call consumes one matching
      # message, so together they prove both files were reported exactly
      # once, in either order, without depending on which arrives first.
      assert_receive {:phoenix_kit_file_trashed, uuid} when uuid in [uuid_a, uuid_b]
      assert_receive {:phoenix_kit_file_trashed, uuid} when uuid in [uuid_a, uuid_b]
    end
  end

  describe "restore_folder/2" do
    test "broadcasts :phoenix_kit_file_restored for every file in the subtree" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(root.uuid)
      file_uuid = file.uuid
      {:ok, _} = Storage.trash_folder(root)
      assert_receive {:phoenix_kit_file_trashed, ^file_uuid}

      assert {:ok, _} = Storage.restore_folder(root)

      assert_receive {:phoenix_kit_file_restored, ^file_uuid}
    end
  end
end
