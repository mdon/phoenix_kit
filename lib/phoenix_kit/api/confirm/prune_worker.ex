defmodule PhoenixKit.API.Confirm.PruneWorker do
  @moduledoc """
  Oban worker that deletes old confirmation codes and decided approvals
  (`phoenix_kit_api_confirmations`).

  Runs daily. A code that was never used is deleted an hour after it ran out (every
  dangerous call without a code inserts one); a used code 30 days after it ran out; an
  approval 30 days after it was decided, executed, failed, found stale or expired. A
  pending, approved or executing approval is never deleted.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.API.Confirm

  @impl Oban.Worker
  def perform(_job) do
    Confirm.prune()
    :ok
  end
end
