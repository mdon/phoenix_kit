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
