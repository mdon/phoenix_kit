defmodule PhoenixKit.UploadsParentFolderTest do
  @moduledoc """
  Unit tests for `PhoenixKit.UploadsParentFolder` — the host placement hook
  for core's own uploads (user avatars, branding logos, media selector
  uploads with a scope). Media hierarchy phase 2, plan 8, task 2.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.UploadsParentFolder
  alias PhoenixKit.Users.Auth

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
        original_file_name: "avatar_#{n}.jpg",
        file_name: "avatar_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
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
        email: "uploads-parent-folder-#{n}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  # ---------------------------------------------------------------------------
  # Fake hooks
  # ---------------------------------------------------------------------------

  defmodule ReturningHook do
    @moduledoc false
    def parent_for(kind, actor_uuid, subject) do
      send(self(), {:hook_called, kind, actor_uuid, subject})
      {:ok, Process.get(:uploads_parent_folder_test_folder_uuid)}
    end
  end

  defmodule TwoArityHook do
    @moduledoc false
    def parent_for(kind, actor_uuid) do
      send(self(), {:hook_called, kind, actor_uuid})
      {:ok, Process.get(:uploads_parent_folder_test_folder_uuid)}
    end
  end

  defmodule NilHook do
    @moduledoc false
    def parent_for(_kind, _actor_uuid, _subject), do: nil
  end

  defmodule RaisingHook do
    @moduledoc false
    def parent_for(_kind, _actor_uuid, _subject), do: raise("boom")
  end

  defmodule ExitingHook do
    @moduledoc false
    def parent_for(_kind, _actor_uuid, _subject), do: exit(:pool_gone)
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit, :uploads_parent_folder) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # resolve/3
  # ---------------------------------------------------------------------------

  describe "resolve/3" do
    test "no hook configured: returns nil" do
      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "3-arity hook configured: returns the folder uuid and receives (kind, actor_uuid, subject)" do
      folder = create_folder!()
      Process.put(:uploads_parent_folder_test_folder_uuid, folder.uuid)

      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      actor_uuid = Ecto.UUID.generate()
      subject = %{some: "subject"}

      assert UploadsParentFolder.resolve(:avatar, actor_uuid, subject) == folder.uuid
      assert_received {:hook_called, :avatar, ^actor_uuid, ^subject}
    end

    test "2-arity hook configured: falls back to (kind, actor_uuid)" do
      folder = create_folder!()
      Process.put(:uploads_parent_folder_test_folder_uuid, folder.uuid)

      Application.put_env(:phoenix_kit, :uploads_parent_folder, {TwoArityHook, :parent_for})

      actor_uuid = Ecto.UUID.generate()

      assert UploadsParentFolder.resolve(:branding, actor_uuid, %{ignored: true}) == folder.uuid
      assert_received {:hook_called, :branding, ^actor_uuid}
    end

    test "hook returns nil: resolve returns nil" do
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {NilHook, :parent_for})

      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "a raising hook returns nil" do
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {RaisingHook, :parent_for})

      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "an exiting hook returns nil" do
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ExitingHook, :parent_for})

      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "an answer that is not a uuid returns nil" do
      Process.put(:uploads_parent_folder_test_folder_uuid, "not-a-uuid")
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "a uuid naming no folder returns nil" do
      Process.put(:uploads_parent_folder_test_folder_uuid, Ecto.UUID.generate())
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      assert UploadsParentFolder.resolve(:avatar, Ecto.UUID.generate(), nil) == nil
    end

    test "a trashed folder returns nil" do
      folder = create_folder!()
      {:ok, _trashed} = Storage.trash_folder(folder, nil)
      Process.put(:uploads_parent_folder_test_folder_uuid, folder.uuid)
      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      assert UploadsParentFolder.resolve(:branding, Ecto.UUID.generate(), nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # place/4
  # ---------------------------------------------------------------------------

  describe "place/4" do
    test "hook configured: attaches the file to the returned folder" do
      user = create_user!()
      file = create_root_file!(user.uuid)
      folder = create_folder!()
      Process.put(:uploads_parent_folder_test_folder_uuid, folder.uuid)

      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      assert :ok = UploadsParentFolder.place(file, :avatar, user.uuid, user)

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == folder.uuid
    end

    test "no hook configured: the file is left untouched" do
      user = create_user!()
      file = create_root_file!(user.uuid)

      assert :ok = UploadsParentFolder.place(file, :avatar, user.uuid, user)

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == nil
    end

    test "a raising hook returns :ok and leaves the file untouched" do
      user = create_user!()
      file = create_root_file!(user.uuid)

      Application.put_env(:phoenix_kit, :uploads_parent_folder, {RaisingHook, :parent_for})

      assert :ok = UploadsParentFolder.place(file, :avatar, user.uuid, user)

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == nil
    end

    # A root file's folder is written through a bare `change/2`, so before the
    # answer was validated a stale uuid raised a foreign-key error here.
    test "a hook answering a stale folder uuid returns :ok and leaves the file at the root" do
      user = create_user!()
      file = create_root_file!(user.uuid)
      Process.put(:uploads_parent_folder_test_folder_uuid, Ecto.UUID.generate())

      Application.put_env(:phoenix_kit, :uploads_parent_folder, {ReturningHook, :parent_for})

      assert :ok = UploadsParentFolder.place(file, :avatar, user.uuid, user)

      reloaded = Storage.get_file(file.uuid)
      assert reloaded.folder_uuid == nil
    end
  end
end
