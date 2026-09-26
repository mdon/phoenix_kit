defmodule PhoenixKit.Modules.Storage.TrashRestoreTest do
  @moduledoc """
  A file in the trash can come back.

  Reported as the trash being one-way: a file could be deleted, but not
  restored, and moving it out of the trash did nothing either — so it read as
  permanently deleted while sitting in a listing that promised otherwise.

  Two halves, and neither was `restore_file/1`, which has always worked:

    * nothing in the media browser offered a restore. `restore_selected`
      existed and handled files and folders, and no template rendered a
      control for it; the trash view's own menu held Move and Delete
      Permanently. The only Restore button in the app was on a file's details
      page, three clicks away through the viewer;
    * moving a trashed file into a folder reported success, wrote the new
      `folder_uuid` onto the trashed row and left it trashed. It never
      appeared in the folder it was dropped on, stayed in the trash, and the
      home it would eventually come back to had quietly changed.

  Moving a trashed file into a folder IS the gesture for taking it out of
  the trash, so it restores it there.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Users.Auth

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "trash-restore-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "t.png",
        file_name: "t.png",
        file_path: "x/t.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp folder!(user, name) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        user_uuid: user.uuid
      })

    folder
  end

  defp fresh(file), do: Repo.get(File, file.uuid)

  setup do
    user = user!()
    media = file!(user)
    a = folder!(user, "a")
    b = folder!(user, "b")

    {:ok, _} = Storage.move_file_to_folder(media.uuid, a.uuid, nil)
    {:ok, _} = Storage.trash_file(fresh(media))

    %{user: user, media: media, a: a, b: b}
  end

  describe "moving a trashed file into a folder" do
    test "takes it out of the trash and puts it there", ctx do
      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.b.uuid, nil)

      file = fresh(ctx.media)
      assert file.status == "active", "it is out of the trash"
      assert is_nil(file.trashed_at)
      assert to_string(file.folder_uuid) == to_string(ctx.b.uuid), "…and in the folder"
    end

    test "it is gone from the trash listing", ctx do
      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.b.uuid, nil)

      refute ctx.media.uuid in Enum.map(Storage.list_trashed_files(), & &1.uuid)
    end

    test "moving it to the root restores it with no folder", ctx do
      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, nil, nil)

      file = fresh(ctx.media)
      assert file.status == "active"
      assert is_nil(file.folder_uuid)
    end

    test "it announces itself, like every other restore", ctx do
      # A trash badge, an open listing and another browser all have a row to
      # bring back. `restore_file/1` has always broadcast; the move path
      # reached the same rows by a different function.
      Storage.subscribe_to_file_events()

      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.b.uuid, nil)

      uuid = ctx.media.uuid
      assert_receive {:phoenix_kit_file_restored, ^uuid}, 1_000
    end

    test "not into a folder that is itself trashed", ctx do
      {:ok, _} = Storage.trash_folder(ctx.b, nil)

      assert {:error, :folder_unavailable} =
               Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.b.uuid, nil)

      assert fresh(ctx.media).status == "trashed", "and it stays where it was"
    end

    test "not out of the scope it was opened in", ctx do
      outside = folder!(ctx.user, "outside")

      assert {:error, :out_of_scope} =
               Storage.move_file_between_folders(
                 ctx.media.uuid,
                 ctx.a.uuid,
                 outside.uuid,
                 ctx.a.uuid
               )

      assert fresh(ctx.media).status == "trashed"
    end
  end

  describe "restoring in place" do
    test "puts the file back where it was", ctx do
      {:ok, _} = Storage.restore_file(fresh(ctx.media))

      file = fresh(ctx.media)
      assert file.status == "active"
      assert to_string(file.folder_uuid) == to_string(ctx.a.uuid)
    end

    test "a restored file is out of the trash listing", ctx do
      {:ok, _} = Storage.restore_file(fresh(ctx.media))
      refute ctx.media.uuid in Enum.map(Storage.list_trashed_files(), & &1.uuid)
    end
  end

  describe "restoring a file whose folder was trashed too" do
    test "it comes back to the nearest folder that still exists", ctx do
      # Trashing a folder trashes what is inside it. Restoring one of those
      # files on its own used to put an ACTIVE file inside a TRASHED folder:
      # gone from the trash, and in a folder the tree no longer shows. The
      # file was fine in the database and unreachable in the app, which is
      # what "it's stuck, it's permanently deleted" looks like from outside.
      parent = folder!(ctx.user, "parent")
      {:ok, child} = Storage.update_folder(ctx.a, %{parent_uuid: parent.uuid})

      {:ok, _} = Storage.restore_file(fresh(ctx.media))
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, child.uuid, nil)
      {:ok, _} = Storage.trash_folder(child, nil)
      assert fresh(ctx.media).status == "trashed"

      {:ok, _} = Storage.restore_file(fresh(ctx.media))

      file = fresh(ctx.media)
      assert file.status == "active"

      assert to_string(file.folder_uuid) == to_string(parent.uuid),
             "the closest live ancestor, not the trashed folder it came from"
    end

    test "and to the root when nothing above it survives", ctx do
      {:ok, _} = Storage.trash_folder(ctx.a, nil)

      {:ok, _} = Storage.restore_file(fresh(ctx.media))

      file = fresh(ctx.media)
      assert file.status == "active"
      assert is_nil(file.folder_uuid), "the root is always reachable"
    end

    test "a live folder is left exactly as it was", ctx do
      {:ok, _} = Storage.restore_file(fresh(ctx.media))
      assert to_string(fresh(ctx.media).folder_uuid) == to_string(ctx.a.uuid)
    end
  end
end
