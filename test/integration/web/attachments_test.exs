defmodule PhoenixKitWeb.AttachmentsTest do
  @moduledoc """
  The upload path every module's file form shares: a finished upload is
  stored under its base name, typed by core's classifier and filed into
  the record's folder by `ResourceFolders.place_stored/2`.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Attachments

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)

    # Stored files go to every enabled bucket; keep them all in this one.
    for bucket <- Storage.list_enabled_buckets(),
        do: {:ok, _} = Storage.update_bucket(bucket, %{enabled: false})

    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_attachments_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "attachments-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{
        "email" => "attachments-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, folder} = Storage.create_folder(%{name: "Record #{n}"})

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
    end)

    %{user: user, folder: folder, n: n}
  end

  defp upload!(bytes) do
    path =
      Path.join(System.tmp_dir!(), "pk_attachments_src_#{System.unique_integer([:positive])}")

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp entry(name, type \\ "application/octet-stream"),
    do: %{client_name: name, client_type: type}

  # Variant jobs cannot be queued without Oban; that is logged, not raised.
  defp store(path, entry, user_uuid, folder_uuid) do
    capture_log(fn ->
      send(self(), {:stored, Attachments.store(path, entry, user_uuid, folder_uuid)})
    end)

    assert_received {:stored, result}
    result
  end

  test "an upload is stored and filed into the folder", %{user: user, folder: folder, n: n} do
    path = upload!("sheet #{n}")
    sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    assert {:ok, file} = store(path, entry("budget.xlsx", sheet), user.uuid, folder.uuid)
    assert file.original_file_name == "budget.xlsx"
    assert file.file_type == "document"
    assert file.ext == "xlsx"
    assert Storage.get_file(file.uuid).folder_uuid == folder.uuid
  end

  test "a path in the browser's file name never reaches storage", %{
    user: user,
    folder: folder,
    n: n
  } do
    path = upload!("path #{n}")

    assert {:ok, file} = store(path, entry("../../etc/Report.PDF"), user.uuid, folder.uuid)
    assert file.original_file_name == "Report.PDF"
    assert file.ext == "pdf"
    assert file.file_type == "document"
  end

  test "a browser's odd file names are stored as plain, bounded names", %{
    user: user,
    folder: folder,
    n: n
  } do
    long = String.duplicate("a", 400) <> ".pdf"

    for {sent, stored} <- [
          {"..", "upload"},
          {".", "upload"},
          {"a\0b.pdf", "ab.pdf"},
          {"line\nbreak.pdf", "linebreak.pdf"},
          {"C:\\Users\\me\\scan.pdf", "scan.pdf"},
          {long, String.duplicate("a", 251) <> ".pdf"},
          # Each of these is one grapheme but two code points.
          {String.duplicate("e\u0301", 300) <> ".pdf",
           String.duplicate("e\u0301", 125) <> "e" <> ".pdf"}
        ] do
      assert {:ok, file} = store(upload!("#{sent} #{n}"), entry(sent), user.uuid, folder.uuid)
      assert file.original_file_name == stored, inspect(sent)
    end
  end

  test "a file with no extension is stored, its extension taken from its type", %{
    user: user,
    folder: folder,
    n: n
  } do
    assert {:ok, readme} =
             store(upload!("readme #{n}"), entry("README", "text/plain"), user.uuid, folder.uuid)

    assert readme.original_file_name == "README"
    assert readme.ext == "txt"
    assert readme.mime_type == "text/plain"

    assert {:ok, blob} = store(upload!("blob #{n}"), entry("blob"), user.uuid, folder.uuid)
    assert blob.ext == "bin"
  end

  test "a file with no extension another user already stored is shared, not refused", %{
    user: user,
    folder: folder,
    n: n
  } do
    {:ok, other} =
      Auth.register_user(%{
        "email" => "attachments-other-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    bytes = "shared readme #{n}"

    assert {:ok, first} =
             store(upload!(bytes), entry("README", "text/plain"), user.uuid, folder.uuid)

    # Processed, as it would be by now outside a test: only an active file is shared.
    {:ok, first} = first |> Ecto.Changeset.change(status: "active") |> Repo.update()

    assert {:ok, copy} =
             store(upload!(bytes), entry("README", "text/plain"), other.uuid, folder.uuid)

    refute copy.uuid == first.uuid
    assert copy.user_uuid == other.uuid
    assert copy.file_path == first.file_path
    assert copy.ext == "txt"
  end

  test "the browser's type is stored, not guessed from the name", %{
    user: user,
    folder: folder,
    n: n
  } do
    assert {:ok, file} =
             store(upload!("typed #{n}"), entry("scan.dat", "image/png"), user.uuid, folder.uuid)

    assert file.mime_type == "image/png"
    assert file.file_type == "image"
  end

  test "a browser type that is not a mime type is ignored, not stored", %{
    user: user,
    folder: folder,
    n: n
  } do
    for {sent, stored} <- [
          {String.duplicate("x", 300) <> "/pdf", "application/pdf"},
          {"not a type", "application/pdf"},
          {"application/pdf; charset=binary", "application/pdf"}
        ] do
      assert {:ok, file} =
               store(upload!("#{sent} #{n}"), entry("doc.pdf", sent), user.uuid, folder.uuid)

      assert file.mime_type == stored, inspect(sent)
    end
  end

  test "the same bytes again are already attached", %{user: user, folder: folder, n: n} do
    assert {:ok, first} = store(upload!("same #{n}"), entry("a.txt"), user.uuid, folder.uuid)

    assert {:already_attached, again} =
             store(upload!("same #{n}"), entry("b.txt"), user.uuid, folder.uuid)

    assert again.uuid == first.uuid
    assert Attachments.duplicate_notice("b.txt", again) =~ "a.txt"
  end

  test "a trashed copy of the same bytes comes back into the folder", %{
    user: user,
    folder: folder,
    n: n
  } do
    assert {:ok, first} = store(upload!("back #{n}"), entry("a.txt"), user.uuid, folder.uuid)
    {:ok, _} = Storage.trash_file(Storage.get_file(first.uuid))

    assert {:ok, restored} = store(upload!("back #{n}"), entry("a.txt"), user.uuid, folder.uuid)
    assert restored.uuid == first.uuid
    assert Storage.get_file(first.uuid).status == "active"
  end

  test "without a folder the file is stored and left unfiled", %{user: user, n: n} do
    assert {:ok, file} = store(upload!("loose #{n}"), entry("x.txt"), user.uuid, nil)
    assert {:ok, again} = store(upload!("loose #{n}"), entry("y.txt"), user.uuid, nil)
    assert again.uuid == file.uuid
  end

  test "without a folder, a trashed copy of the same bytes comes back live", %{user: user, n: n} do
    # A form that files on save (CRM's composer) stages what this returns;
    # a trashed row would stage, then fail to attach, and be lost.
    assert {:ok, first} = store(upload!("staged #{n}"), entry("a.txt"), user.uuid, nil)
    {:ok, _} = Storage.trash_file(Storage.get_file(first.uuid))

    assert {:ok, again} = store(upload!("staged #{n}"), entry("a.txt"), user.uuid, nil)
    assert again.uuid == first.uuid
    assert again.status == "active"
    assert Storage.get_file(first.uuid).status == "active"
  end

  test "nobody signed in stores nothing", %{folder: folder, n: n} do
    assert Attachments.store(upload!("anon #{n}"), entry("x.txt"), nil, folder.uuid) ==
             {:error, :no_user}

    assert Attachments.failed_message("x.txt", :no_user) == Attachments.error_message(:no_user)
  end

  test "a failure is an error, never a raise", %{user: user, folder: folder} do
    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 Attachments.store(
                   "/nonexistent/#{System.unique_integer()}",
                   entry("x.txt"),
                   user.uuid,
                   folder.uuid
                 )
      end)

    assert log =~ "Storing an upload failed"
  end
end
