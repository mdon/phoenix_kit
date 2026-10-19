defmodule PhoenixKit.Modules.Storage.HiddenLibraryTest do
  @moduledoc """
  A hidden system library (`Libraries.create_system_library(attrs, hidden: true)`):
  a module's own store. It is not listed with the site's libraries, its files and
  folders are left out of every site listing, its files get only expiring URLs,
  and only their uploader (and an Owner/Admin) may read them — a holder of
  `media` + `media.view_all` may not. Dedup works inside it as in any library,
  and never reaches into it from outside.
  """

  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, URLSigner}
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.FileController

  @media Libraries.media_uuid()
  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_hidden_library_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "hidden-library-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    {:ok, manager_role} = Roles.create_role(%{name: "Managers #{n}"})

    for key <- ~w(media media.view_all media.manage),
        do: {:ok, _} = Permissions.grant_permission(manager_role.uuid, key)

    {:ok, hidden} =
      Libraries.create_system_library(%{name: "Assistant #{n}", slug: "assistant-#{n}"},
        hidden: true
      )

    %{
      n: n,
      hidden: hidden,
      uploader: user!("uploader"),
      manager: user!("manager", manager_role)
    }
  end

  defp user!(tag, role \\ nil) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "hidden-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp store(user, library_uuid, content) do
    source = Path.join(System.tmp_dir!(), "pk_hidden_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "image", user.uuid, checksum, "jpg", "a.jpg", opts)
      end)

    File.rm(source)
    result
  end

  defp uuids(rows), do: Enum.map(rows, & &1.uuid)

  describe "creating one" do
    test "hidden: true makes a private system library; without it nothing changes", %{
      hidden: hidden,
      n: n
    } do
      assert %Library{kind: "system", visibility: "private"} = hidden
      assert Libraries.hidden?(hidden)
      assert Libraries.hidden?(hidden.uuid)
      assert Libraries.system_library?(hidden.uuid)

      {:ok, plain} = Libraries.create_system_library(%{name: "Plain #{n}"})
      assert plain.visibility == "site"
      refute Libraries.hidden?(plain)
      refute Libraries.hidden?(@media)
      refute Libraries.private?(plain.uuid)
    end

    test "a visibility in the attrs (what a form posts) does not hide a library", %{n: n} do
      {:ok, library} =
        Libraries.create_system_library(%{"name" => "Posted #{n}", "visibility" => "private"})

      assert library.visibility == "site"
      refute Libraries.hidden?(library)
    end
  end

  describe "listing" do
    test "it is not one of the site's libraries, but its owner finds it by slug", %{
      hidden: hidden
    } do
      refute hidden.uuid in uuids(Libraries.list_system_libraries())

      refute hidden.uuid in Enum.map(
               Libraries.list_system_libraries_with_stats(),
               & &1.library.uuid
             )

      refute Libraries.get_system_library(hidden.uuid)
      refute Libraries.get_system_library_with_stats(hidden.uuid)
      refute Libraries.get_system_library_by_slug(hidden.slug)

      assert Libraries.get_library(hidden.uuid).uuid == hidden.uuid
      assert Libraries.get_hidden_library_by_slug(hidden.slug).uuid == hidden.uuid
      refute Libraries.get_hidden_library_by_slug("no-such-library")
      refute Libraries.get_hidden_library_by_slug(nil)
    end

    test "a site library is not found as a hidden one", %{n: n} do
      {:ok, plain} = Libraries.create_system_library(%{name: "Site #{n}"})
      refute Libraries.get_hidden_library_by_slug(plain.slug)
    end

    test "its files and folders stay out of listings that name no library", %{
      hidden: hidden,
      uploader: uploader,
      n: n
    } do
      {:ok, file} = store(uploader, hidden.uuid, "hidden listing #{n}")
      assert file.library_uuid == hidden.uuid

      {:ok, folder} =
        Storage.create_folder(%{name: "hidden-folder-#{n}", library_uuid: hidden.uuid})

      {files, _} = Storage.list_files_in_scope(nil, per_page: 1000)
      refute file.uuid in uuids(files)

      refute folder.uuid in uuids(Storage.list_folders(nil, nil))
      refute folder.uuid in Enum.map(Storage.list_folder_tree(nil), & &1.folder.uuid)
      assert [] == Storage.search_folders("hidden-folder-#{n}", nil, nil)

      # Named explicitly (the module that owns it), it is listed.
      {files, _} = Storage.list_files_in_scope(nil, library_uuid: hidden.uuid)
      assert file.uuid in uuids(files)

      assert folder.uuid in Enum.map(
               Storage.list_folder_tree(nil, library_uuid: hidden.uuid),
               & &1.folder.uuid
             )
    end
  end

  describe "access" do
    test "a holder of media.view_all can neither read nor edit its files; the uploader and an Admin can",
         %{hidden: hidden, uploader: uploader, manager: manager, n: n} do
      {:ok, file} = store(uploader, hidden.uuid, "hidden access #{n}")
      {admin, _token} = PhoenixKitWeb.ConnCase.create_admin_user()

      refute Libraries.can?(scope(manager), file, :read)
      refute Libraries.can?(scope(manager), file, :edit)
      refute Storage.authorized_url(scope(manager), file, "original")

      assert Libraries.can?(scope(uploader), file, :read)
      # Owner/Admin read any file of Storage (`Scope.system_role?/1`), as before.
      assert Libraries.can?(scope(admin), file, :read)
    end

    test "a holder of media.view_all still edits a site library's files", %{
      uploader: uploader,
      manager: manager,
      n: n
    } do
      {:ok, plain} = Libraries.create_system_library(%{name: "Editable #{n}"})
      {:ok, file} = store(uploader, plain.uuid, "site library edit #{n}")
      assert Libraries.can?(scope(manager), file, :edit)
    end

    test "its files take only an expiring URL; the permanent one is refused", %{
      hidden: hidden,
      uploader: uploader,
      n: n
    } do
      {:ok, file} = store(uploader, hidden.uuid, "hidden url #{n}")
      assert Libraries.private_file?(file)

      permanent = URLSigner.generate_token(file.uuid, "original")

      conn =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => permanent
        })

      assert conn.status == 401

      # The uploader's URL is a time-window one, and it serves.
      url = Storage.authorized_url(scope(uploader), file, "original")
      [token] = url |> String.split("/") |> Enum.take(-1)
      assert "w" <> _ = token

      conn =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => token
        })

      assert conn.status == 200
    end
  end

  describe "dedup" do
    test "the same bytes uploaded to Media after the hidden library give a new, visible file",
         %{hidden: hidden, uploader: uploader, n: n} do
      content = "reverse dedup #{n}"
      {:ok, hidden_file} = store(uploader, hidden.uuid, content)

      assert {:ok, media_file} = store(uploader, nil, content)
      assert media_file.uuid != hidden_file.uuid
      assert media_file.library_uuid == @media

      {files, _} = Storage.list_files_in_scope(nil, library_uuid: @media, per_page: 1000)
      assert media_file.uuid in uuids(files)
      refute Libraries.private_file?(media_file)

      # And through the plain `store_file/2`, which names no library.
      source = Path.join(System.tmp_dir!(), "pk_hidden_plain_#{n}")
      File.write!(source, content)

      {{:ok, plain}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Storage.store_file(source,
            filename: "a.jpg",
            content_type: "image/jpeg",
            size_bytes: byte_size(content),
            user_uuid: uploader.uuid
          )
        end)

      File.rm(source)
      assert plain.library_uuid == @media
      refute plain.uuid == hidden_file.uuid
    end

    test "another uploader's Media upload of the same bytes is not cloned from the hidden file",
         %{hidden: hidden, uploader: uploader, manager: manager, n: n} do
      content = "cross user #{n}"
      {:ok, hidden_file} = store(uploader, hidden.uuid, content)

      assert {:ok, other} = store(manager, nil, content)
      assert other.library_uuid == @media
      refute other.file_path == hidden_file.file_path
    end

    test "inside the hidden library a second upload is the same file", %{
      hidden: hidden,
      uploader: uploader,
      n: n
    } do
      content = "direct dedup #{n}"
      {:ok, first} = store(uploader, hidden.uuid, content)

      assert {:ok, again, :duplicate} = store(uploader, hidden.uuid, content)
      assert again.uuid == first.uuid
      assert again.library_uuid == hidden.uuid
    end
  end
end
