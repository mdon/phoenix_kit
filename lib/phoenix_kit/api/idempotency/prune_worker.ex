defmodule PhoenixKit.API.Idempotency.PruneWorker do
  @moduledoc """
  Oban worker that deletes expired idempotency records (`phoenix_kit_api_idempotency`).

  Runs daily. A record lives `api_idempotency_ttl_hours` (default 24) after it was
  claimed; an expired record that has not been pruned yet is already treated as absent by
  `PhoenixKit.API.Idempotency.claim/4`, so the schedule only keeps the table small.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.API.Idempotency

  @impl Oban.Worker
  def perform(_job) do
    Idempotency.prune()
    :ok
  end
end
