defmodule PhoenixKit.Modules.Storage.Workers.DeleteOrphanedFileJob do
  @moduledoc """
  Oban job that moves a single orphaned file to the trash.

  Never deletes: an orphan is a guess (nothing known references the file),
  so it goes where a person can still restore it. The daily trash prune
  (`PruneTrashJob`) deletes it for good after `trash_retention_days`. The
  name is kept so jobs queued before this changed still run.

  Verifies the file is still orphaned first, in case it was referenced
  again after being queued.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}}) do
    case Storage.get_file(file_uuid) do
      nil ->
        # Already deleted
        :ok

      file ->
        if Storage.file_orphaned?(file_uuid) do
          case Storage.trash_file(file) do
            {:ok, _} ->
              Logger.info("DeleteOrphanedFileJob: moved orphaned file #{file_uuid} to the trash")
              :ok

            {:error, reason} ->
              Logger.warning(
                "DeleteOrphanedFileJob: failed to trash file #{file_uuid}: #{inspect(reason)}"
              )

              {:error, reason}
          end
        else
          Logger.info("DeleteOrphanedFileJob: file #{file_uuid} is still referenced, skipping")
          :ok
        end
    end
  end
end
