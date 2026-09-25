defmodule PhoenixKit.Modules.Storage.Locations do
  @moduledoc """
  Where a stored object is: its `phoenix_kit_file_locations` rows (V204).

  An object is named by its key (`FileInstance.file_name`). Several
  instances may share one key (a cross-user copy, a tile written twice), and
  each instance has one location row per bucket that holds the object
  (`phoenix_kit_file_locations_instance_bucket_index`).

  `PhoenixKit.Modules.Storage.Manager` reads, serves and checks objects
  through this: the buckets the rows name come first, then the other
  enabled buckets, and when one of those turns out to hold the object, a row
  is recorded for it (`record/2`). That fallback is what keeps files stored
  before every writer recorded its locations working while
  `Storage.Workers.LocationBackfillJob` has not reached them yet.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage.{FileInstance, FileLocation}

  @doc "The uuids of the buckets the active location rows of `key` name."
  @spec bucket_uuids(String.t()) :: [String.t()]
  def bucket_uuids(key) when is_binary(key) do
    from(l in FileLocation,
      where: l.path == ^key and l.status == "active",
      distinct: true,
      select: l.bucket_uuid
    )
    |> repo().all()
    |> Enum.map(&to_string/1)
  rescue
    # A lookup must never stop a read: without it the manager tries every
    # bucket, as it did before V204.
    error ->
      Logger.warning("Storage: location lookup for #{key} failed: #{Exception.message(error)}")
      []
  end

  def bucket_uuids(_key), do: []

  @doc """
  Records that `bucket_uuid` holds the object at `key`: an active location
  row for every instance stored under that key that has none on that
  bucket. Returns how many rows were added. Never raises.
  """
  @spec record(String.t(), term()) :: non_neg_integer()
  def record(key, bucket_uuid) when is_binary(key) and not is_nil(bucket_uuid) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      from(i in FileInstance,
        left_join: l in FileLocation,
        on: l.file_instance_uuid == i.uuid and l.bucket_uuid == ^bucket_uuid,
        where: i.file_name == ^key and is_nil(l.uuid),
        select: i.uuid
      )
      |> repo().all()
      |> Enum.map(fn instance_uuid ->
        %{
          uuid: UUIDv7.generate(),
          path: key,
          status: "active",
          priority: 0,
          last_verified_at: now,
          file_instance_uuid: instance_uuid,
          bucket_uuid: bucket_uuid,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      0
    else
      {count, _} =
        repo().insert_all(FileLocation, rows,
          on_conflict: :nothing,
          conflict_target: [:file_instance_uuid, :bucket_uuid]
        )

      count
    end
  rescue
    error ->
      Logger.warning(
        "Storage: recording #{key} on #{bucket_uuid} failed: #{Exception.message(error)}"
      )

      0
  end

  def record(_key, _bucket_uuid), do: 0

  @doc """
  Records every bucket in `bucket_uuids` for `key` (`record/2` each): what a
  writer calls once its instance row exists, with the buckets the manager
  stored the object in.
  """
  @spec record_all(String.t(), [term()]) :: non_neg_integer()
  def record_all(key, bucket_uuids) when is_list(bucket_uuids),
    do: bucket_uuids |> Enum.map(&record(key, &1)) |> Enum.sum()

  @doc """
  Orders `buckets` so the ones in `located` come first, each group keeping
  its own order. The first group is where the rows say the object is; the
  second is the fallback.
  """
  @spec located_first([map()], [String.t()]) :: {[map()], [map()]}
  def located_first(buckets, located) do
    Enum.split_with(buckets, &(to_string(&1.uuid) in located))
  end

  @doc "How many instances have no location row at all."
  @spec missing_count() :: non_neg_integer()
  def missing_count do
    from(i in FileInstance,
      as: :instance,
      where:
        not exists(
          from(l in FileLocation,
            where: l.file_instance_uuid == parent_as(:instance).uuid,
            select: 1
          )
        ),
      select: count(i.uuid)
    )
    |> repo().one()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
