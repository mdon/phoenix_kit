defmodule PhoenixKit.Jobs.ObanStore do
  @moduledoc """
  Reads of Oban's own `oban_jobs` table, routed the way Oban routes them.

  `Oban.Job` carries no PhoenixKit `@schema_prefix`, so `Repo.get(Oban.Job, id)`
  reads the connection's default schema — the wrong table on an install whose
  Oban lives in a named schema (`config :app, Oban, prefix: "..."`), and a table
  that may not exist at all. Oban inserts a dispatch with its configured prefix;
  everything that looks at the dispatch again must go through the same
  configuration. This module is the one place that does.

  Every function answers `:unavailable` (or the given default) when no Oban
  instance runs in this VM — a script, a web-only node — because such a caller
  cannot tell what became of a job, and must not guess.
  """

  import Ecto.Query

  alias PhoenixKit.Jobs.Run

  @doc """
  The Oban job `id` as the current dispatch of `run`, or `nil` when there is none
  that belongs to it: never made, pruned, or a row of another worker, run or
  generation (an integer id alone proves nothing). `:unavailable` when Oban cannot
  be asked.
  """
  @spec dispatch_of(Run.t()) :: Oban.Job.t() | nil | :unavailable
  def dispatch_of(%Run{oban_job_id: nil}), do: nil

  def dispatch_of(%Run{oban_job_id: id} = run) do
    case with_config(&Oban.Repo.get(&1, Oban.Job, id)) do
      :unavailable -> :unavailable
      %Oban.Job{} = job -> if dispatch?(job, run), do: job, else: nil
      nil -> nil
    end
  end

  defp dispatch?(%Oban.Job{worker: worker, args: args}, %Run{} = run) do
    worker == inspect(PhoenixKit.Jobs.RunWorker) and
      args["run_uuid"] == run.uuid and args["generation"] == run.generation
  end

  @doc "`Oban.Repo.all/2` for `query` against Oban's configured prefix and repo."
  @spec all(Ecto.Queryable.t()) :: list()
  def all(query), do: call(&Oban.Repo.all(&1, query), fn -> repo().all(query) end)

  @doc "`Oban.Repo.one/2` for `query`."
  @spec one(Ecto.Queryable.t()) :: term()
  def one(query), do: call(&Oban.Repo.one(&1, query), fn -> repo().one(query) end)

  @doc "`Oban.Repo.aggregate/3` for `query`."
  @spec aggregate(Ecto.Queryable.t(), :count | :sum | :avg | :min | :max) :: term()
  def aggregate(query, kind),
    do: call(&Oban.Repo.aggregate(&1, query, kind), fn -> repo().aggregate(query, kind) end)

  @doc "The Oban job counts by state."
  @spec state_counts() :: %{String.t() => non_neg_integer()}
  def state_counts do
    from(j in Oban.Job, group_by: j.state, select: {j.state, count(j.id)})
    |> all()
    |> Map.new()
  end

  # Runs `fun` with the running Oban instance's configuration. Without one, a
  # lookup that has a sensible default (a page listing) falls back to the repo's
  # own schema; a dispatch lookup answers `:unavailable`.
  defp with_config(fun) do
    fun.(Oban.config())
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp call(with_conf, fallback) do
    case with_config(with_conf) do
      :unavailable -> fallback.()
      result -> result
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
