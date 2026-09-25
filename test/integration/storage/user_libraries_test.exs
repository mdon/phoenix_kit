defmodule PhoenixKit.Modules.Storage.UserLibrariesTest do
  @moduledoc """
  User libraries (V203), end to end against the database: who may create
  them and how many, what members may do, trashing and the default, what
  deleting a user does to their libraries and uploads, purging, per-library
  dedup, and the per-file access check.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, LibraryMember}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_setting("storage_user_library_limit", "3")

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Librarians #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    {:ok, reader_role} = Roles.create_role(%{name: "Readers #{n}"})
    {:ok, _} = Permissions.grant_permission(reader_role.uuid, "storage")

    %{role: role, reader_role: reader_role}
  end

  defp user!(role \\ nil) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "user-libraries-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp library!(user, name \\ "Lib #{System.unique_integer([:positive])}") do
    {:ok, library} = Libraries.create_user_library(scope(user), %{"name" => name})
    library
  end

  defp member!(owner, library, user, role) do
    {:ok, member} = Libraries.add_member(scope(owner), library, user.email, role)
    member
  end

  describe "site listings" do
    test "a user library's file is not site media and not an orphan", %{role: role} do
      user = user!(role)
      library = library!(user, "Private")
      private_id = file!(user, library.uuid)
      media_id = file!(user, nil)

      refute Storage.file_orphaned?(private_id)
      assert Storage.file_orphaned?(media_id)

      {listed, _} = Storage.list_files_in_scope(nil, page: 1, per_page: 100)
      ids = Enum.map(listed, & &1.uuid)
      refute private_id in ids
      assert media_id in ids

      refute private_id in (Storage.find_orphaned_files() |> Enum.map(& &1.uuid))
    end

    test "inside a user library nothing is an orphan, so nothing is bulk-deleted as one",
         %{role: role} do
      user = user!(role)
      library = library!(user, "Root Files")
      file!(user, library.uuid)

      # A root file in a user library is referenced by nothing in the site,
      # which is exactly what an orphan looks like; the browser's "Delete all
      # orphaned" inside the library would have deleted it.
      assert Storage.find_orphaned_files(library_uuid: library.uuid) == []
      assert Storage.count_orphaned_files(nil, library_uuid: library.uuid) == 0
    end
  end

  describe "who may have libraries" do
    test "nobody while user libraries are off", %{role: role} do
      user = user!(role)
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", false)

      refute Libraries.may_use_libraries?(scope(user))
      refute Libraries.may_create_library?(scope(user))
      assert {:error, :not_allowed} = Libraries.create_user_library(scope(user), %{"name" => "X"})
    end

    test "storage to use them, storage.create_library to create them", ctx do
      creator = user!(ctx.role)
      reader = user!(ctx.reader_role)
      plain = user!()

      assert Libraries.may_create_library?(scope(creator))
      assert Libraries.may_use_libraries?(scope(reader))
      refute Libraries.may_create_library?(scope(reader))
      refute Libraries.may_use_libraries?(scope(plain))

      assert {:error, :not_allowed} =
               Libraries.create_user_library(scope(reader), %{"name" => "Mine"})
    end
  end

  describe "creating" do
    test "a private user library with a key prefix and a slug; the first is the default",
         %{role: role} do
      user = user!(role)
      first = library!(user, "Personal Photos")
      second = library!(user, "Work")

      assert %Library{kind: "user", visibility: "private", is_default: true} = first
      assert first.owner_uuid == user.uuid
      assert first.slug == "personal-photos"
      assert first.key_prefix =~ ~r/\Alib-[0-9a-f]{12}\z/
      refute second.is_default
      assert Libraries.default_user_library(user.uuid).uuid == first.uuid
    end

    test "names and slugs are unique per owner, not site-wide", %{role: role} do
      one = user!(role)
      other = user!(role)

      a = library!(one, "Family")
      b = library!(other, "Family")
      assert a.slug == "family" and b.slug == "family"

      assert {:error, %Ecto.Changeset{} = changeset} =
               Libraries.create_user_library(scope(one), %{"name" => "family"})

      assert changeset.errors[:name]
    end

    test "the per-user limit counts live libraries", %{role: role} do
      user = user!(role)
      libraries = for i <- 1..3, do: library!(user, "L#{i}")

      assert {:error, :limit_reached} =
               Libraries.create_user_library(scope(user), %{"name" => "L4"})

      {:ok, _} = Libraries.trash_library(scope(user), hd(libraries))
      assert %Library{} = library!(user, "L4")
    end
  end

  describe "members" do
    test "roles decide what a member may do", ctx do
      owner = user!(ctx.role)
      manager = user!(ctx.reader_role)
      viewer = user!(ctx.reader_role)
      library = library!(owner)

      member!(owner, library, manager, "manager")
      member!(owner, library, viewer, "viewer")

      assert Libraries.role(library, owner.uuid) == :owner
      assert Libraries.role(library, manager.uuid) == :manager
      assert Libraries.role(library, viewer.uuid) == :viewer

      assert Libraries.allows?(:manager, :members)
      refute Libraries.allows?(:manager, :own)
      assert Libraries.allows?(:contributor, :upload)
      refute Libraries.allows?(:contributor, :edit_any)
      refute Libraries.allows?(:viewer, :upload)

      # A viewer manages nobody; a manager does.
      stranger = user!(ctx.reader_role)

      assert {:error, :not_allowed} =
               Libraries.add_member(scope(viewer), library, stranger.email, "viewer")

      assert {:ok, %LibraryMember{}} =
               Libraries.add_member(scope(manager), library, stranger.email, "contributor")

      # Only the owner trashes, whatever a manager may do.
      assert {:error, :not_allowed} = Libraries.trash_library(scope(manager), library)
      assert {:ok, _} = Libraries.rename_user_library(scope(manager), library, "Renamed")
    end

    test "the member's list shows their libraries; the owner is never a member row", ctx do
      owner = user!(ctx.role)
      member = user!(ctx.reader_role)
      library = library!(owner, "Shared One")
      member!(owner, library, member, "contributor")

      assert [%{library: %{uuid: uuid}, role: :contributor}] =
               Libraries.list_user_libraries(member.uuid)

      assert uuid == library.uuid
      assert {:error, :owner} = Libraries.add_member(scope(owner), library, owner.email, "viewer")

      assert {:error, :no_such_user} =
               Libraries.add_member(scope(owner), library, "nobody@example.com", "viewer")

      assert {:error, %Ecto.Changeset{}} =
               Libraries.add_member(scope(owner), library, member.email, "viewer")
    end

    test "a member finds a shared library by uuid, the owner by slug too", ctx do
      owner = user!(ctx.role)
      member = user!(ctx.reader_role)
      library = library!(owner, "Findable")
      member!(owner, library, member, "viewer")

      assert %{role: :owner} = Libraries.get_user_library(scope(owner), "findable")
      assert %{role: :viewer} = Libraries.get_user_library(scope(member), library.uuid)
      refute Libraries.get_user_library(scope(member), "findable")
      refute Libraries.get_user_library(scope(user!(ctx.role)), library.uuid)

      assert Libraries.url_id(library, owner.uuid) == "findable"
      assert Libraries.url_id(library, member.uuid) == library.uuid
    end

    test "role changes and removal; a member may leave", ctx do
      owner = user!(ctx.role)
      member = user!(ctx.reader_role)
      library = library!(owner)
      member!(owner, library, member, "viewer")

      assert {:ok, %{role: "manager"}} =
               Libraries.update_member_role(scope(owner), library, member.uuid, "manager")

      assert {:error, %Ecto.Changeset{}} =
               Libraries.update_member_role(scope(owner), library, member.uuid, "owner")

      assert :ok = Libraries.remove_member(scope(member), library, member.uuid)
      assert Libraries.role(library, member.uuid) == nil
    end
  end

  describe "trashing" do
    test "frees the name and slug, hides it from members, and passes the default on", ctx do
      owner = user!(ctx.role)
      member = user!(ctx.reader_role)
      first = library!(owner, "Alpha")
      _second = library!(owner, "Beta")
      member!(owner, first, member, "viewer")

      assert {:ok, trashed} = Libraries.trash_library(scope(owner), first)
      assert trashed.trashed_at
      assert trashed.slug == nil
      refute trashed.is_default

      assert Libraries.default_user_library(owner.uuid).name == "Beta"
      assert Libraries.list_user_libraries(member.uuid) == []
      assert Libraries.role(trashed, member.uuid) == nil
      assert %Library{slug: "alpha"} = library!(owner, "Alpha")
    end
  end

  describe "restoring" do
    test "the owner restores a trashed library with a slug, as the default if none", ctx do
      owner = user!(ctx.role)
      library = library!(owner, "Comeback")
      {:ok, trashed} = Libraries.trash_library(scope(owner), library)

      assert [%Library{uuid: uuid}] = Libraries.list_trashed_user_libraries(owner.uuid)
      assert uuid == library.uuid

      assert {:error, :not_allowed} =
               Libraries.restore_library(scope(user!(ctx.role)), trashed)

      assert {:ok, restored} = Libraries.restore_library(scope(owner), trashed)
      assert restored.trashed_at == nil
      assert restored.slug == "comeback"
      assert restored.is_default
      assert Libraries.list_trashed_user_libraries(owner.uuid) == []
    end

    test "a name taken meanwhile, or the limit, refuses it", ctx do
      owner = user!(ctx.role)
      library = library!(owner, "Taken")
      {:ok, trashed} = Libraries.trash_library(scope(owner), library)
      _new = library!(owner, "Taken")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Libraries.restore_library(scope(owner), trashed)

      assert changeset.errors[:name]

      other = library!(owner, "Other")
      {:ok, other_trashed} = Libraries.trash_library(scope(owner), other)
      library!(owner, "Fill 1")
      library!(owner, "Fill 2")

      assert {:error, :limit_reached} = Libraries.restore_library(scope(owner), other_trashed)
    end
  end

  describe "deleting a user" do
    test "trashes the libraries they own and keeps their uploads elsewhere", ctx do
      {admin, _} = create_admin!()
      owner = user!(ctx.role)
      own = library!(owner, "Mine")

      other_owner = user!(ctx.role)
      shared = library!(other_owner, "Theirs")
      member!(other_owner, shared, owner, "contributor")

      in_media = file!(owner, nil)
      in_shared = file!(owner, shared.uuid)
      in_own = file!(owner, own.uuid)

      assert {:ok, _} = Auth.delete_user(owner, %{current_user: admin})

      assert %Library{trashed_at: %DateTime{}, owner_uuid: nil} = Repo.get!(Library, own.uuid)
      assert Repo.get!(Storage.File, in_media).user_uuid == nil
      assert Repo.get!(Storage.File, in_shared).user_uuid == nil
      assert Repo.get!(Storage.File, in_own).library_uuid == own.uuid
      assert Libraries.list_members(shared) == []
    end
  end

  describe "purging" do
    test "a live library is refused; a trashed one goes with its files and folders", ctx do
      owner = user!(ctx.role)
      library = library!(owner)
      file = file!(owner, library.uuid)

      {:ok, folder} =
        Storage.create_folder(%{name: "In the library", library_uuid: library.uuid})

      assert {:error, :not_trashed} = Libraries.purge_library(library)

      {:ok, trashed} = Libraries.trash_library(scope(owner), library)
      assert :ok = Libraries.purge_library(trashed)

      refute Repo.get(Library, library.uuid)
      refute Repo.get(Storage.File, file)
      refute Repo.get(Storage.Folder, folder.uuid)
    end

    test "the daily prune queues the ones whose owner is gone", ctx do
      owner = user!(ctx.role)
      library = library!(owner)
      {:ok, _} = Libraries.trash_library(scope(owner), library)

      assert Libraries.queue_expired_purges(30) == 0

      Repo.query!(
        "UPDATE phoenix_kit_storage_libraries SET owner_uuid = NULL WHERE uuid = $1::text::uuid",
        [library.uuid]
      )

      assert Libraries.queue_expired_purges(30) == 1
    end
  end

  describe "the per-file check" do
    test "members read a user library's files; owner and managers edit them", ctx do
      owner = user!(ctx.role)
      manager = user!(ctx.reader_role)
      viewer = user!(ctx.reader_role)
      stranger = user!(ctx.reader_role)
      library = library!(owner)
      member!(owner, library, manager, "manager")
      member!(owner, library, viewer, "viewer")

      file = %{user_uuid: owner.uuid, library_uuid: library.uuid}

      for user <- [owner, manager, viewer], do: assert(Libraries.can?(scope(user), file, :read))
      refute Libraries.can?(scope(stranger), file, :read)

      assert Libraries.can?(scope(manager), file, :edit)
      refute Libraries.can?(scope(viewer), file, :edit)

      # A holder of "media" edits system-library files, never a user library's.
      {:ok, media_role} = Roles.create_role(%{name: "Media #{System.unique_integer()}"})
      {:ok, _} = Permissions.grant_permission(media_role.uuid, "media")
      media_holder = user!(media_role)
      refute Libraries.can?(scope(media_holder), file, :edit)
      assert Libraries.can?(scope(media_holder), %{file | library_uuid: nil}, :edit)
    end
  end

  describe "dedup" do
    test "one copy per uploader per library: the same bytes land once in each", ctx do
      with_local_bucket(fn ->
        user = user!(ctx.role)
        library = library!(user)

        assert {:ok, in_media} = store!(user, nil, "same bytes")
        assert {:ok, in_library} = store!(user, library.uuid, "same bytes")
        assert {:ok, again, :duplicate} = store!(user, library.uuid, "same bytes")

        assert in_media.uuid != in_library.uuid
        assert in_library.library_uuid == library.uuid
        assert again.uuid == in_library.uuid

        # Media keeps the key every file had before libraries existed.
        assert in_media.user_file_checksum ==
                 Storage.calculate_user_file_checksum(user.uuid, in_media.file_checksum)
      end)
    end
  end

  defp create_admin! do
    {:ok, admin} =
      Auth.register_user(%{
        "email" => "ul-admin-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Roles.assign_role(admin, "Admin")
    {Repo.get!(Auth.User, admin.uuid), nil}
  end

  defp file!(user, library_uuid) do
    attrs = %{
      original_file_name: "a.png",
      file_name: "a.png",
      file_path: "x/a.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: Ecto.UUID.generate(),
      user_file_checksum: Ecto.UUID.generate(),
      size: 1,
      status: "active",
      user_uuid: user.uuid
    }

    attrs = if library_uuid, do: Map.put(attrs, :library_uuid, library_uuid), else: attrs
    {:ok, file} = Storage.create_file(attrs)
    file.uuid
  end

  defp with_local_bucket(fun) do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_user_libraries_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "user-libraries-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    try do
      fun.()
    after
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end
  end

  defp store!(user, library_uuid, content) do
    source =
      Path.join(System.tmp_dir!(), "pk_user_libraries_#{System.unique_integer([:positive])}.txt")

    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(
          source,
          "document",
          user.uuid,
          checksum,
          "txt",
          "a.txt",
          opts
        )
      end)

    File.rm(source)
    result
  end
end
