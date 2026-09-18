defmodule PhoenixKit.Users.LoginAttemptsPruneWorker do
  @moduledoc """
  Oban worker that prunes old failed sign-in buckets.

  Runs daily. Retention comes from the `login_attempt_retention_days` setting
  (default: 90), matching `activity_retention_days`.

  Pruning is by `last_at`, not `first_at` — a bucket that is still being added
  to is still live, however long ago it opened.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.Users.LoginAttempts

  @impl Oban.Worker
  def perform(_job) do
    LoginAttempts.prune(LoginAttempts.retention_days())
    :ok
  end
end
