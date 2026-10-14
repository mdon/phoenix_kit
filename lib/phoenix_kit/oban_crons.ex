defmodule PhoenixKit.ObanCrons do
  @moduledoc """
  The Oban cron jobs installed modules declare, so a host does not have to copy them into
  its config by hand.

  A module declares its scheduled workers with the optional `c:PhoenixKit.Module.oban_crons/0`
  callback, next to `c:PhoenixKit.Module.oban_queues/0`:

      @impl PhoenixKit.Module
      def oban_crons, do: [{"0 3 * * *", MyModule.Workers.NightlyRebuild}]

  `mix phoenix_kit.install` writes every declared entry into the new crontab and
  `mix phoenix_kit.update` adds the ones an existing crontab is missing
  (`PhoenixKit.Install.ObanConfig.ensure_module_cron_entries/3`). The host's say wins, as
  it does for core's own workers: a schedule the host wrote is never changed, and an entry
  the host commented out of its crontab is a declined entry that is not offered again.

  Entries are read from **every installed module**, enabled or not, and a module is found
  without the registry when the installer runs before it exists (the same rule as
  `PhoenixKit.ObanQueues`). A worker should do nothing while its module is switched off.

  ## One entry per worker

  The installer decides whether an entry is already there by the worker's name, so a worker
  has one schedule and no `args`. If two modules declare the same worker with different
  schedules, the first (modules sorted by name) wins and the other is reported as a
  conflict.

  ## What is dropped

  An entry is ignored, with a warning, when the cron expression is not one Oban's own
  parser accepts (`Oban.Cron.parse/1`, or `Oban.Plugins.Cron.parse/1` before Oban 2.24
  renamed the plugin) or the worker is not a loaded Elixir module exporting `perform/1`.
  That is deliberate:
  Oban refuses to start when its crontab names something that is not a worker, so one bad
  declaration must not reach the host's config.
  """

  require Logger

  alias PhoenixKit.ObanQueues

  @typedoc "One cron entry: the schedule and the worker."
  @type entry :: {String.t(), module()}

  @typedoc "Two modules declaring one worker with different schedules."
  @type conflict :: %{
          worker: module(),
          kept: entry(),
          kept_owner: module(),
          ignored: entry(),
          ignored_owner: module()
        }

  @doc """
  The cron entries to configure, one per worker, and the conflicts found on the way.

  `modules` defaults to the registered modules when the registry is running and to a
  `.beam` scan otherwise (the install and update tasks run before the registry exists).
  """
  @spec declared([module()] | nil) :: {[entry()], [conflict()]}
  def declared(modules \\ nil) do
    (modules || ObanQueues.installed_modules())
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
    |> Enum.flat_map(&module_crons/1)
    |> merge()
  end

  @doc "A one-line description of a conflict, for the installer's output."
  @spec describe_conflict(conflict()) :: String.t()
  def describe_conflict(
        %{worker: worker, kept: {kept_cron, _}, ignored: {ignored_cron, _}} = conflict
      ) do
    "Oban cron: #{inspect(worker)} is declared by #{inspect(conflict.kept_owner)} at " <>
      "#{inspect(kept_cron)} and by #{inspect(conflict.ignored_owner)} at " <>
      "#{inspect(ignored_cron)}; keeping #{inspect(kept_cron)}"
  end

  defp module_crons(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :oban_crons, 0) do
      module.oban_crons() |> normalize(module)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKit] #{inspect(module)}.oban_crons/0 failed: #{Exception.message(error)}"
      )

      []
  end

  # Accepts `[{cron, worker}]`; drops (with a warning) anything else, so one malformed
  # declaration cannot take the installer down or reach a host's config.
  defp normalize(declared, owner) when is_list(declared) do
    Enum.flat_map(declared, fn entry ->
      case normalize_entry(entry) do
        {:ok, normalized} ->
          [{owner, normalized}]

        :error ->
          Logger.warning(
            "[PhoenixKit] ignoring invalid Oban cron declaration #{inspect(entry)} from " <>
              "#{inspect(owner)}: expected {cron, worker}, a cron expression Oban accepts and " <>
              "a loaded worker module"
          )

          []
      end
    end)
  end

  defp normalize(declared, owner) do
    Logger.warning(
      "[PhoenixKit] #{inspect(owner)} declared Oban crons as #{inspect(declared)}; " <>
        "expected a list of {cron, worker}"
    )

    []
  end

  defp normalize_entry({cron, worker}) when is_binary(cron) and is_atom(worker) do
    cron = cron |> String.split() |> Enum.join(" ")

    if valid_cron?(cron) and worker?(worker), do: {:ok, {cron, worker}}, else: :error
  end

  defp normalize_entry(_entry), do: :error

  defp valid_cron?(cron) do
    case parser() do
      nil ->
        Logger.warning(
          "[PhoenixKit] cannot validate Oban cron expressions: this Oban version has no " <>
            "Oban.Cron.parse/1 or Oban.Plugins.Cron.parse/1"
        )

        false

      parser ->
        match?({:ok, _}, parser.parse(cron))
    end
  rescue
    _ in [ArgumentError, FunctionClauseError] -> false
  end

  # Oban 2.24 moved the public parser from `Oban.Plugins.Cron` to `Oban.Cron`; `mix.exs`
  # allows both. A dynamic call keeps the version that is not installed out of the compile.
  defp parser do
    Enum.find([Oban.Cron, Oban.Plugins.Cron], fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :parse, 1)
    end)
  end

  # An Elixir module (`Elixir.` alias): the installer writes the worker with `inspect/1`
  # and looks it up by `Module.concat/1`, which an Erlang-style atom would not survive.
  defp worker?(worker) do
    elixir_module?(worker) and Code.ensure_loaded?(worker) and
      function_exported?(worker, :perform, 1)
  end

  defp elixir_module?(module), do: match?("Elixir." <> _, Atom.to_string(module))

  # First declaration of a worker wins; the same entry again is a shared declaration, a
  # different schedule is a conflict.
  defp merge(owned_entries) do
    {kept, conflicts} =
      Enum.reduce(owned_entries, {%{}, []}, fn {owner, {_cron, worker} = entry},
                                               {kept, conflicts} ->
        case Map.fetch(kept, worker) do
          :error ->
            {Map.put(kept, worker, {owner, entry}), conflicts}

          {:ok, {_owner, ^entry}} ->
            {kept, conflicts}

          {:ok, {kept_owner, kept_entry}} ->
            conflict = %{
              worker: worker,
              kept: kept_entry,
              kept_owner: kept_owner,
              ignored: entry,
              ignored_owner: owner
            }

            {kept, [conflict | conflicts]}
        end
      end)

    ordered =
      owned_entries
      |> Enum.map(fn {_owner, {_cron, worker}} -> worker end)
      |> Enum.uniq()
      |> Enum.map(fn worker -> kept |> Map.fetch!(worker) |> elem(1) end)

    {ordered, Enum.reverse(conflicts)}
  end
end
