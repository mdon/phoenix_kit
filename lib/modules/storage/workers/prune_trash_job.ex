defmodule PhoenixKit.Modules.Storage.Workers.PruneTrashJob do
  @moduledoc """
  Oban worker that permanently deletes trashed files older than the configured retention period.

  Runs daily via cron. Retention is configured via the `trash_retention_days` setting (default: 30).
  It also queues the purge of user libraries trashed longer ago than that,
  and of those whose owner is gone (`Libraries.queue_expired_purges/1`).
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Workers.{ChecksumBackfillJob, LocationBackfillJob}

  @impl Oban.Worker
  def perform(_job) do
    days = Storage.trash_retention_days()

    # Records where objects stored before V204 are, while any are left.
    _ = LocationBackfillJob.maybe_enqueue()
    _ = ChecksumBackfillJob.maybe_enqueue()

    case Libraries.queue_expired_purges(days) do
      0 -> :ok
      count -> Logger.info("PruneTrashJob: queued the purge of #{count} trashed libraries")
    end

    case Storage.prune_trash(days) do
      {:ok, 0} ->
        Logger.debug("PruneTrashJob: no expired trashed files to clean up")
        :ok

      {:ok, count} ->
        Logger.info("PruneTrashJob: permanently deleted #{count} expired trashed files")
        :ok
    end
  end
end
