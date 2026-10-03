defmodule PhoenixKit.Jobs.SweepWorker do
  @moduledoc """
  Finds the runs that stopped without saying so and puts them right — the
  run-level twin of `Oban.Plugins.Lifeline` (which only rescues the Oban row).
  Cron, every five minutes (`mix phoenix_kit.update` adds the entry to existing
  hosts).

  It reads each active run's **own Oban job** (`oban_job_id`), never "is there any
  job", and never a stale heartbeat alone (`dev_docs/plans/2026-10-03-job-runs.md`,
  §14 R5):

  | the run | its Oban job | action |
  |---|---|---|
  | holds a claim | `executing` | leave it (Lifeline owns a genuinely dead one) |
  | holds a claim | anything else | the batch died: **release** the claim |
  | waiting | `available`, `scheduled`, `retryable`, `executing` | leave it |
  | waiting | `discarded` | its attempts are spent: the run **fails** |
  | waiting | `cancelled` outside the engine | the run **fails** |
  | waiting | `completed`, or gone, or of another generation | a lost dispatch: **rescue** |

  A rescue gives the run a new generation and dispatches it, and is counted on the
  row (`rescues`), so the budget survives restarts; at `@rescue_limit` the run fails
  instead of restarting for ever. A run changed in the last `@grace_seconds` is
  left alone: its dispatch may be in flight.

  Each pass stamps `job_runs_last_sweep_at`, which the Jobs page reads to warn when
  no sweeper has been seen.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  import Ecto.Query

  require Logger

  alias PhoenixKit.Jobs.{Engine, Run}
  alias PhoenixKit.Settings

  @rescue_limit 3
  @grace_seconds 120
  @setting "job_runs_last_sweep_at"

  @doc "The setting the last pass stamps, an ISO 8601 timestamp."
  def last_sweep_setting, do: @setting

  @impl Oban.Worker
  def perform(_job) do
    result = sweep()

    if result != %{released: 0, failed: 0, rescued: 0} do
      Logger.info("Jobs sweep: #{inspect(result)}")
    end

    :ok
  end

  @doc """
  One pass. Returns how many claims were released, runs failed and dispatches
  rescued. Public so a test, a Mix task or the Jobs page can run it now.
  """
  @spec sweep(DateTime.t()) :: %{released: integer(), failed: integer(), rescued: integer()}
  def sweep(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    cutoff = DateTime.add(now, -@grace_seconds, :second)

    result =
      from(r in Run,
        where:
          r.state in ["queued", "running", "pausing", "cancelling"] and r.updated_at < ^cutoff,
        order_by: r.inserted_at
      )
      |> repo().all()
      |> Enum.reduce(%{released: 0, failed: 0, rescued: 0}, fn run, acc ->
        merge(acc, handle(run))
      end)

    Settings.update_setting(@setting, DateTime.to_iso8601(now))
    result
  end

  defp merge(acc, outcome) do
    case outcome do
      :released -> %{acc | released: acc.released + 1}
      :failed -> %{acc | failed: acc.failed + 1}
      :rescued -> %{acc | rescued: acc.rescued + 1}
      :left -> acc
    end
  end

  defp handle(%Run{claim_token: token} = run) when not is_nil(token) do
    case job_state(run) do
      {"executing", _job} ->
        :left

      _ ->
        case Engine.transition(
               run.uuid,
               {:checkpoint, token,
                {:release, "the batch did not finish (a crash or a timeout)"}},
               mode: "auto"
             ) do
          {:ok, %Run{state: state} = released} when state in ["queued", "running"] ->
            # Once released, a run with a dead job is judged like any waiting one.
            case handle_waiting(released) do
              :left -> :released
              other -> other
            end

          # A pause or cancel that was waiting for the dead batch has settled.
          {:ok, _settled} ->
            :released

          {:error, _reason} ->
            :left
        end
    end
  end

  defp handle(%Run{state: state} = run) when state in ["queued", "running"],
    do: handle_waiting(run)

  defp handle(%Run{}), do: :left

  defp handle_waiting(%Run{} = run) do
    case job_state(run) do
      {state, _job} when state in ~w(available scheduled retryable executing) ->
        :left

      {"discarded", job} ->
        fail(run, "the batch used up its attempts: #{last_error(job)}")

      {"cancelled", _job} ->
        fail(run, "its Oban job was cancelled outside the run")

      _lost ->
        rescue_run(run)
    end
  end

  # The state of the run's current dispatch, or nil when there is none that
  # belongs to this generation (never made, pruned, or an older one).
  defp job_state(%Run{oban_job_id: nil}), do: nil

  defp job_state(%Run{oban_job_id: id, generation: generation}) do
    case repo().get(Oban.Job, id) do
      %Oban.Job{args: %{"generation" => ^generation}, state: state} = job -> {state, job}
      _ -> nil
    end
  end

  defp fail(run, message) do
    case Engine.transition(run.uuid, {:fail, message}, mode: "auto") do
      {:ok, _run} -> :failed
      {:error, _reason} -> :left
    end
  end

  defp rescue_run(run) do
    case Engine.transition(run.uuid, {:rescue, @rescue_limit}, mode: "auto") do
      {:ok, %Run{state: "failed"}} -> :failed
      {:ok, _run} -> :rescued
      {:error, _reason} -> :left
    end
  end

  defp last_error(%Oban.Job{errors: [_ | _] = errors}) do
    errors |> List.last() |> Map.get("error", "unknown error")
  end

  defp last_error(_job), do: "unknown error"

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
