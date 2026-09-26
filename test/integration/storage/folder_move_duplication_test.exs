defmodule PhoenixKit.Modules.Storage.FolderMoveDuplicationTest do
  @moduledoc """
  Dragging a file from one folder onto another moves it. It does not leave a
  copy behind.

  Reported as a file "duplicating" — staying in the folder it was dragged out
  of and appearing in the one it was dropped on. It takes two folders and a
  file that has been attached somewhere, which is ordinary: a post's featured
  image, a product's gallery and the uploader's content-duplicate path all go
  through `ResourceFolders.attach/2` → `Storage.attach_file_to_folder/2`,
  which LINKS a file that already has a home rather than moving it.

    * `set_home/2` wrote `folder_uuid` and left any link to that same folder
      in place, so the file was both homed in the folder and linked into it.
      A listing cannot show that — `folder_uuid = $1 OR linked` answers once
      either way — so it sat there silently;
    * the next move asked the link table what the gesture meant before asking
      where the file lived, took the link path for a file whose home was
      right there, and re-pointed the link at the target while the home
      stayed put. One file, two folders.

  A folder holds a file ONCE: as its home, or through a link, never both.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FolderLink}
  alias PhoenixKit.Users.Auth

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "folder-move-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "m.png",
        file_name: "m.png",
        file_path: "x/m.png",
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

  defp linked?(file, folder),
    do:
      Repo.one(
        from(l in FolderLink,
          where: l.file_uuid == ^file.uuid and l.folder_uuid == ^folder.uuid,
          select: count()
        )
      ) == 1

  defp home?(file, folder), do: to_string(fresh(file).folder_uuid) == to_string(folder.uuid)

  # What a listing shows: the folder's own files plus the ones linked into it.
  defp shows?(file, folder), do: home?(file, folder) or linked?(file, folder)

  describe "a file that was attached somewhere and then moved in" do
    setup do
      user = user!()
      file = file!(user)
      a = folder!(user, "a")
      b = folder!(user, "b")
      c = folder!(user, "c")

      {:ok, _} = Storage.move_file_to_folder(file.uuid, a.uuid, nil)
      # A featured image, a gallery entry, a re-upload of something already
      # held elsewhere: all of these link rather than move.
      {:ok, _} = Storage.attach_file_to_folder(fresh(file), b.uuid)

      %{media: file, a: a, b: b, c: c}
    end

    test "moving it into that folder consumes the link", ctx do
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.b.uuid, nil)

      assert home?(ctx.media, ctx.b)

      refute linked?(ctx.media, ctx.b),
             "a folder holds a file once — homed AND linked is the pair that " <>
               "the next move turns into a duplicate"
    end

    test "and moving it out again leaves nothing behind", ctx do
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.b.uuid, nil)
      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.b.uuid, ctx.c.uuid, nil)

      assert shows?(ctx.media, ctx.c), "it arrives"
      refute shows?(ctx.media, ctx.b), "and it leaves — this is the reported bug"
      refute shows?(ctx.media, ctx.a)
    end

    test "a stale pair already in the database still moves cleanly", ctx do
      # The rows a database written by the old code is carrying: the setup's
      # link into B, and a home written straight onto the column the way
      # `set_home/2` used to. The move has to cope with the pair, not just
      # stop making it.
      Repo.update!(Ecto.Changeset.change(fresh(ctx.media), %{folder_uuid: ctx.b.uuid}))
      assert home?(ctx.media, ctx.b) and linked?(ctx.media, ctx.b), "the corrupt pair"

      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.b.uuid, ctx.c.uuid, nil)

      assert shows?(ctx.media, ctx.c)
      refute shows?(ctx.media, ctx.b)
    end
  end

  describe "deleting a folder does not make the pair either" do
    test "a file re-homed to the parent loses the parent's link" do
      # `delete_folder/2` lifts a folder's files to its parent, and the
      # parent is exactly the kind of folder those files may already be
      # attached to — the same pair by a different door.
      user = user!()
      parent = folder!(user, "parent")
      child = folder!(user, "child")
      {:ok, child} = Storage.update_folder(child, %{parent_uuid: parent.uuid})
      file = file!(user)

      {:ok, _} = Storage.move_file_to_folder(file.uuid, child.uuid, nil)
      {:ok, _} = Storage.attach_file_to_folder(fresh(file), parent.uuid)
      assert linked?(file, parent)

      {:ok, _} = Storage.delete_folder(child, nil)

      assert home?(file, parent), "the file is lifted to the parent"
      refute linked?(file, parent), "and the link it arrived with is consumed"
    end
  end

  describe "what a move means is decided by where the file lives" do
    setup do
      user = user!()
      file = file!(user)

      %{
        user: user,
        media: file,
        a: folder!(user, "a"),
        b: folder!(user, "b"),
        c: folder!(user, "c")
      }
    end

    test "home in the source: the file moves", ctx do
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.a.uuid, nil)
      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.c.uuid, nil)

      assert home?(ctx.media, ctx.c)
      refute shows?(ctx.media, ctx.a)
    end

    test "merely linked into the source: the link moves and the home stays", ctx do
      # Unchanged, and the reason the link path exists: the folder holding a
      # file's home keeps it, and every other folder's link is its own.
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.a.uuid, nil)
      {:ok, _} = Storage.attach_file_to_folder(fresh(ctx.media), ctx.b.uuid)

      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.b.uuid, ctx.c.uuid, nil)

      assert home?(ctx.media, ctx.a),
             "its home is not the business of the folder it was linked into"

      assert linked?(ctx.media, ctx.c)
      refute shows?(ctx.media, ctx.b)
    end

    test "a link to a third folder is left alone by a home move", ctx do
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.a.uuid, nil)
      {:ok, _} = Storage.attach_file_to_folder(fresh(ctx.media), ctx.b.uuid)

      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, ctx.c.uuid, nil)

      assert home?(ctx.media, ctx.c)
      assert linked?(ctx.media, ctx.b), "B put that link there and nobody asked for it to go"
    end

    test "dragging to the root takes the home away and keeps other folders' links", ctx do
      {:ok, _} = Storage.move_file_to_folder(ctx.media.uuid, ctx.a.uuid, nil)
      {:ok, _} = Storage.attach_file_to_folder(fresh(ctx.media), ctx.b.uuid)

      {:ok, _} = Storage.move_file_between_folders(ctx.media.uuid, ctx.a.uuid, nil, nil)

      assert is_nil(fresh(ctx.media).folder_uuid)
      refute shows?(ctx.media, ctx.a)
      assert linked?(ctx.media, ctx.b)
    end
  end
end
