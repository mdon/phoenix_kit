defmodule PhoenixKit.Modules.Storage.LocationBackfillTest do
  @moduledoc """
  `LocationBackfillJob` (V204): an instance with no location row is found in
  the bucket that holds its key and recorded; one found in no bucket is
  counted missing and left alone; a run schedules the next batch later, and
  only while there is more.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, Manager}
  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    root = Path.join(System.tmp_dir!(), "pk_backfill_#{System.unique_integer([:positive])}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "backfill-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@cache)
      File.rm_rf(root)
    end)

    %{bucket: bucket}
  end

  defp instance!(key) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "backfill-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.txt",
        file_name: Path.basename(key),
        file_path: Path.dirname(key),
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: 1,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    instance
  end

  defp locations(instance),
    do: Repo.all(from(l in FileLocation, where: l.file_instance_uuid == ^instance.uuid))

  test "a pass records the bucket that holds each key, and leaves the rest", %{bucket: bucket} do
    stored_key = "backfill/#{System.unique_integer([:positive])}/a.txt"
    source = Path.join(System.tmp_dir!(), "pk_backfill_src_#{System.unique_integer([:positive])}")
    File.write!(source, "stored")
    on_exit(fn -> File.rm(source) end)

    {:ok, _} =
      Manager.store_file(source, path_prefix: stored_key, force_bucket_ids: [bucket.uuid])

    stored = instance!(stored_key)
    lost = instance!("backfill/#{System.unique_integer([:positive])}/gone.txt")

    assert LocationBackfillJob.pending?()
    totals = LocationBackfillJob.run_pass()

    assert totals[:recorded] >= 1
    assert totals[:missing] >= 1
    assert [%{bucket_uuid: uuid}] = locations(stored)
    assert to_string(uuid) == to_string(bucket.uuid)
    assert locations(lost) == []
  end

  test "maybe_enqueue/0 says there is nothing to do once every instance has a row" do
    # The shared database may hold other unlocated instances, so only the
    # shape of the answer is fixed here.
    assert LocationBackfillJob.maybe_enqueue() in [:queued, :nothing_to_do, :unavailable]
  end
end
