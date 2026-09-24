defmodule PhoenixKit.Modules.Storage.Workers.PurgeLibraryJob do
  @moduledoc """
  Oban worker that purges one trashed storage library: its files (bytes
  included, through the normal delete path), its folders, then the library
  (`PhoenixKit.Modules.Storage.Libraries.purge_library/1`).

  Queued when a user's libraries are trashed because the user is deleted,
  and by the daily trash prune for libraries trashed longer ago than the
  retention period. A library that is gone, or no longer trashed, is left
  alone.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 5, unique: [period: 3600]

  alias PhoenixKit.Modules.Storage.Libraries

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_uuid" => uuid}}) do
    case Libraries.purge_library(uuid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_trashed} -> {:cancel, :not_trashed}
    end
  end
end
