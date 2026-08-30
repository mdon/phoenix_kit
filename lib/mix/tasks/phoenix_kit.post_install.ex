defmodule Mix.Tasks.PhoenixKit.PostInstall do
  @shortdoc "Post-install steps for PhoenixKit (migration prompt, asset rebuild)"

  @moduledoc """
  Runs the PhoenixKit install steps that must happen AFTER the installer's
  file changes have landed on disk.

  `mix phoenix_kit.install` queues this task with `Igniter.add_task/3` rather
  than doing the work in its own `run/1`. That distinction is load-bearing:
  the entry point our docs recommend, `mix igniter.install phoenix_kit`,
  never calls the installer's `run/1` at all. Igniter composes installers
  through `Igniter.Mix.Task.configure_and_run/3`, which invokes the task's
  `igniter/1` callback and nothing else — so work parked in `run/1` silently
  does not happen on the recommended path. A queued task runs on both paths,
  and is skipped on `--dry-run`, where running a migration would be wrong.

  ## Steps

    * offer to run `mix ecto.migrate` (interactive terminals only — skipped
      under CI or with no `TERM`, with a note saying why)
    * rebuild assets, unless `--skip-assets`

  Both shell out to a fresh `mix` process on purpose: the install just
  rewrote `config/config.exs`, and this VM still holds the configuration it
  booted with.

  ## Options

    * `--prefix SCHEMA` — the PostgreSQL schema the install targeted
    * `--skip-assets` — skip the asset rebuild

  Normally invoked for you. Running it by hand is safe and idempotent: it
  re-reads the migration state from disk and offers the same choices.
  """

  use Mix.Task

  alias PhoenixKit.Install.{AssetRebuild, MigrationStrategy}

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, switches: [prefix: :string, skip_assets: :boolean])

    MigrationStrategy.handle_interactive_migration_after_config(opts)

    unless Keyword.get(opts, :skip_assets, false) do
      AssetRebuild.check_and_rebuild(verbose: true)
    end

    :ok
  end
end
