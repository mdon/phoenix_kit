defmodule PhoenixKit.Modules.Storage.ChecksumBackfillTest do
  @moduledoc """
  `ChecksumBackfillJob` (G12): a file the upload API stored with an MD5
  checksum gets the SHA-256 of its stored bytes and the matching dedup key,
  so it dedups against the same bytes uploaded any other way; one whose
  uploader already has those bytes as another file is left as it is.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Workers.ChecksumBackfillJob
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    root = Path.join(System.tmp_dir!(), "pk_checksum_#{System.unique_integer([:positive])}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "checksum-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{
        "email" => "checksum-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    on_exit(fn ->
      :persistent_term.erase(@cache)
      File.rm_rf(root)
    end)

    %{user: user}
  end

  defp sha(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
  defp md5(content), do: :md5 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  # Stored the way the upload API used to: its checksum is the MD5.
  defp stored!(user, content) do
    source = Path.join(System.tmp_dir!(), "pk_checksum_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    on_exit(fn -> File.rm(source) end)

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, md5(content), "txt", "a.txt")
      end)

    {:ok, file} = result
    file
  end

  test "an MD5 row gets its bytes' SHA-256 and the matching dedup key", %{user: user} do
    content = "api upload #{System.unique_integer([:positive])}"
    file = stored!(user, content)
    assert file.file_checksum == md5(content)

    assert ChecksumBackfillJob.recompute(file) == :updated

    updated = Storage.get_file(file.uuid)
    assert updated.file_checksum == sha(content)

    assert updated.user_file_checksum ==
             Storage.calculate_user_file_checksum(user.uuid, sha(content), updated.library_uuid)
  end

  test "a row whose uploader already has the bytes is left as it is", %{user: user} do
    content = "twice #{System.unique_integer([:positive])}"
    old = stored!(user, content)

    source = Path.join(System.tmp_dir!(), "pk_checksum_sha_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    on_exit(fn -> File.rm(source) end)

    {{:ok, _sha_copy}, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, sha(content), "txt", "b.txt")
      end)

    assert ChecksumBackfillJob.recompute(old) == :duplicate
    assert Storage.get_file(old.uuid).file_checksum == md5(content)
  end
end
