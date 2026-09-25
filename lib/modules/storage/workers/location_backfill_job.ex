defmodule PhoenixKit.Modules.Storage.Workers.LocationBackfillJob do
  @moduledoc """
  Records where the objects stored before location-truth are (V204).

  Every writer records a `phoenix_kit_file_locations` row for each bucket it
  stores an object in, and marks its instances checked. Instances stored
  earlier by writers that did not (Tessera tiles, comment attachments) are
  unchecked. This job walks them in `@batch_size` batches, in uuid order,
  checks each enabled bucket for the instance's key once, records every
  bucket that has it (`Storage.Locations.record/2`), and marks the instance
  checked with how many held it (`Locations.mark_checked/2`) — a miss too,
  so it is not work again and the Health count reaches zero.

  "Unchecked", not "has no location row": a read that finds a key in a
  bucket records that one bucket, which must not retire the instance from
  this walk while its other copies are unrecorded.

  **Throttled.** One batch per run, and the next run is scheduled
  `@pause_seconds` later, on the `file_processing` queue, so a large or
  remote bucket is walked at a steady pace instead of all at once.

  **Queued by itself** (the maintainer's decision, plan §"Next: V204"):
  `PhoenixKit.Supervisor` calls `maybe_enqueue/0` shortly after boot, and
  the daily trash prune does too, whenever any instance has no row. Only one
  pending run exists at a time (`unique` over `[:worker, :queue]`, ignoring
  the cursor). Reads keep working meanwhile: the manager checks the other
  buckets for a key with no rows, and records what it finds.

  `run_pass/1` runs a whole pass in the calling process.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Locations, ProviderRegistry}

  @batch_size 50
  @pause_seconds 5

  @doc "Queues a pass when any instance is unchecked. Never raises."
  @spec maybe_enqueue() :: :queued | :nothing_to_do | :unavailable
  def maybe_enqueue do
    if pending?() do
      case %{} |> new() |> Oban.insert() do
        {:ok, _job} -> :queued
        _ -> :unavailable
      end
    else
      :nothing_to_do
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "Whether any instance is unchecked."
  @spec pending?() :: boolean()
  def pending? do
    repo().exists?(missing_query(nil))
  end

  @doc "How many instances are unchecked (for the Health page)."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Locations.missing_count()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case run_batch(args["after"], %{}) do
      {:more, last_uuid, _totals} ->
        {:ok, _job} =
          %{"after" => last_uuid} |> new(schedule_in: @pause_seconds) |> Oban.insert()

        :ok

      {:done, totals} ->
        Logger.info("LocationBackfillJob: pass finished #{inspect(totals)}")
        :ok
    end
  end

  @doc """
  Runs a whole pass in the calling process, batch after batch, and returns
  how many instances were `:recorded` and how many were `:missing` (in no
  enabled bucket). `progress` is called with the running totals.
  """
  @spec run_pass((map() -> any())) :: %{atom() => non_neg_integer()}
  def run_pass(progress \\ fn _totals -> :ok end), do: run_pass(nil, %{}, progress)

  defp run_pass(cursor, totals, progress) do
    case run_batch(cursor, totals) do
      {:more, last_uuid, totals} ->
        progress.(totals)
        run_pass(last_uuid, totals, progress)

      {:done, totals} ->
        progress.(totals)
        totals
    end
  end

  # One batch after `cursor`: `{:more, last_uuid, totals}` while a full batch
  # was read, `{:done, totals}` once the walk has passed the last instance.
  defp run_batch(cursor, totals) do
    buckets = Storage.list_enabled_buckets()

    batch =
      cursor
      |> missing_query()
      |> then(&from(i in &1, order_by: i.uuid, limit: @batch_size, select: {i.uuid, i.file_name}))
      |> repo().all()

    totals =
      Enum.reduce(batch, totals, fn {uuid, key}, acc ->
        found = locate(key, buckets)
        # Checked, found or not: a miss is remembered, so it is not work again.
        Locations.mark_checked([uuid], found)
        outcome = if found > 0, do: :recorded, else: :missing
        Map.update(acc, outcome, 1, &(&1 + 1))
      end)

    case batch do
      [] -> {:done, totals}
      _ when length(batch) < @batch_size -> {:done, totals}
      _ -> {:more, batch |> List.last() |> elem(0) |> to_string(), totals}
    end
  end

  # Checks every enabled bucket for `key` once; returns how many hold it,
  # each one recorded.
  defp locate(key, buckets) when is_binary(key) do
    buckets
    |> Enum.filter(fn bucket ->
      case ProviderRegistry.get_provider(bucket.provider) do
        {:ok, provider} -> safe_exists?(provider, bucket, key)
        _ -> false
      end
    end)
    |> Enum.map(fn bucket ->
      Locations.record(key, bucket.uuid)
      bucket
    end)
    |> length()
  end

  defp locate(_key, _buckets), do: 0

  defp safe_exists?(provider, bucket, key) do
    provider.file_exists?(bucket, key)
  rescue
    error ->
      Logger.warning(
        "LocationBackfillJob: could not check #{key} on #{bucket.name}: #{Exception.message(error)}"
      )

      false
  end

  defp missing_query(nil), do: Locations.unchecked_query()

  defp missing_query(after_uuid),
    do: from(i in Locations.unchecked_query(), where: i.uuid > ^after_uuid)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
