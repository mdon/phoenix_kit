defmodule PhoenixKit.Modules.Storage.Workers.ReconcileJob do
  @moduledoc """
  Runs `PhoenixKit.Modules.Storage.Reconciler` over the stale files (V205):
  copies objects where a library's storage profile wants them, unlinks them
  where it no longer does, and makes, remakes or deletes sizes by its
  variant set.

  **Throttled**, like the location backfill: `@batch_size` files per run,
  the next run `@pause_seconds` later, on the `file_processing` queue, so
  its copying and its ImageMagick/FFmpeg work stay bounded by that queue.
  Only one pending run exists at a time (`unique` over `[:worker, :queue]`,
  ignoring the cursor): a change queued while a pass is under way starts
  the walk again from the beginning (a waiting next batch is replaced).
  A file that could not be finished waits ten minutes before it is tried
  again (`reconcile_attempted_at`), so a restart does not retry the same
  failing files ahead of the rest.

  **Queued by itself** (`enqueue/0`): whenever a profile, a variant set or
  one of their rows changes (their revision is bumped), a library moves to
  another profile or set, an upload makes fewer copies or sizes than
  wanted, and by the daily trash prune and on boot while any file is stale.
  It never waits for a person; the Health page shows what is left.

  It replaces `SyncFilesJob`, the Health page's manual sync.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  require Logger

  alias PhoenixKit.Modules.Storage.Reconciler

  @batch_size 10
  @pause_seconds 2

  @doc """
  Queues a pass from the beginning. Never raises: a change must not fail
  because Oban is not running (a test, a Mix task); the daily prune and the
  next boot queue one anyway.
  """
  # A pass already waiting (between batches, or queued behind other jobs) is
  # replaced, not kept: its cursor would skip the files before it that this
  # change made stale.
  @spec enqueue() :: :queued | :unavailable
  def enqueue do
    replace = [scheduled: [:args, :scheduled_at], available: [:args]]

    case %{} |> new(replace: replace) |> Oban.insert() do
      {:ok, _job} -> :queued
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "Queues a pass when any file is stale. Never raises."
  @spec maybe_enqueue() :: :queued | :nothing_to_do | :unavailable
  def maybe_enqueue do
    if Reconciler.pending?(), do: enqueue(), else: :nothing_to_do
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Reconciler.run_batch(args["after"], @batch_size) do
      {:more, last_uuid, _totals} ->
        {:ok, _job} =
          %{"after" => last_uuid} |> new(schedule_in: @pause_seconds) |> Oban.insert()

        :ok

      {:done, totals} ->
        Logger.info("ReconcileJob: pass finished #{inspect(totals)}")
        :ok
    end
  end

  # A batch copies objects and makes sizes: video transcodes take minutes.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @doc """
  Runs a whole pass in the calling process and returns the totals
  (`:reconciled`, `:stale`, `:skipped`). For tests and Mix tasks.
  """
  @spec run_pass() :: map()
  def run_pass, do: run_pass(nil, %{})

  defp run_pass(cursor, totals) do
    case Reconciler.run_batch(cursor, @batch_size, totals) do
      {:more, last_uuid, totals} -> run_pass(last_uuid, totals)
      {:done, totals} -> totals
    end
  end
end
