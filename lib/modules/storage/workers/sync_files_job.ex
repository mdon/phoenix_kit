defmodule PhoenixKit.Modules.Storage.Workers.SyncFilesJob do
  @moduledoc """
  Kept so that a sync queued before V205 still has a worker to run: it only
  queues `PhoenixKit.Modules.Storage.Workers.ReconcileJob`, which replaced
  the Health page's manual sync (copies are now made where each library's
  storage profile wants them, by itself). Remove after one release.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 1

  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = ReconcileJob.maybe_enqueue()
    :ok
  end
end
