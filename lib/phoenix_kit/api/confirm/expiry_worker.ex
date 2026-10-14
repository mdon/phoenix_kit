defmodule PhoenixKit.API.Confirm.ExpiryWorker do
  @moduledoc """
  Oban worker that keeps the approval queue honest.

  Runs every five minutes. It marks pending approvals and unused confirmation codes
  whose time has passed as `expired`, and fails every approval that has been `approved`
  or `executing` for 15 minutes without a change: the page or process that was running it
  died, and the operation may be half done. Its partial results stay on the row; the
  error is `interrupted`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.API.Confirm

  @impl Oban.Worker
  def perform(_job) do
    Confirm.expire_due()
    Confirm.sweep_stuck()
    :ok
  end
end
