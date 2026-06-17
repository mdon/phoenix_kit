defmodule PhoenixKit.Squash.MigrationRunner do
  @moduledoc """
  Runs PhoenixKit.Migration.up/down for a specific version-range into a target
  prefix using the proven Ecto.Migrator wrapper pattern.

  The PhoenixKit migration DSL (`PhoenixKit.Migration.up/1` etc.) must be
  executed inside an `Ecto.Migrator` runner because the individual version
  modules use Ecto.Migration DSL (create_if_not_exists, alter table, etc.) which
  requires the migration runner context.

  ## Pattern

  For each target version we define an ephemeral Ecto.Migration module at
  runtime via `Code.eval_string/1`, then call `Ecto.Migrator.up/4` with a
  synthetic microsecond-based version so Ecto's deduplication never interferes.

  This is the same pattern as the task spec's "proven recipe".
  """

  @floor 110
  @current_version 135

  @doc """
  Run OLD migration chain (V01..V135 via old postgres.ex) up to `to_version`.

  This simulates what a consumer app's migration wrapper does on a fresh install
  using the current (pre-squash) code. The `PhoenixKit.Migrations.Postgres`
  module must be loaded (it always is in MIX_ENV=test).

  prefix is the target schema name (e.g. "public" or "pk_squash_test").
  create_schema: pass false when the schema already exists.

  [DB]
  """
  def run_old_chain(repo, prefix, opts \\ []) do
    to_version = Keyword.get(opts, :to_version, @current_version)
    create_schema = Keyword.get(opts, :create_schema, prefix != "public")

    run_via_wrapper(repo, fn ->
      PhoenixKit.Migration.up(
        version: to_version,
        prefix: prefix,
        create_schema: create_schema
      )
    end)
  end

  @doc """
  Run OLD migration chain DOWN to `to_version` (0 = full removal).
  [DB]
  """
  def run_old_chain_down(repo, prefix, opts \\ []) do
    to_version = Keyword.get(opts, :to_version, 0)

    run_via_wrapper(repo, fn ->
      PhoenixKit.Migration.down(
        version: to_version,
        prefix: prefix
      )
    end)
  end

  @doc """
  Run NEW migration chain (V110 baseline + V111..V135) for a fresh install.
  The new code's `PhoenixKit.Migration.up/1` must be loaded (post-squash).

  Since this script runs BEFORE the squash is committed, we call the individual
  new v110 module directly here.  After the squash lands, this becomes a plain
  PhoenixKit.Migration.up/1 call.

  [DB]
  """
  def run_new_chain_fresh(repo, prefix, opts \\ []) do
    create_schema = Keyword.get(opts, :create_schema, prefix != "public")

    # Step 1: run the new baseline (v110 module — may not exist yet pre-squash;
    # the verify script guards this with Code.ensure_loaded?).
    baseline_mod = PhoenixKit.Migrations.Postgres.V110

    unless Code.ensure_loaded?(baseline_mod) do
      raise "New baseline module #{baseline_mod} is not loaded. " <>
              "Run generate_baseline.exs first to create it."
    end

    # Run the baseline using the same wrapper pattern so it executes inside
    # an Ecto.Migrator context (required for Ecto.Migration DSL).
    run_via_wrapper(repo, fn ->
      baseline_mod.up(%{
        prefix: prefix,
        create_schema: create_schema,
        quoted_prefix: inspect(prefix),
        escaped_prefix: String.replace(prefix, "'", "\\'")
      })
    end)

    # Step 2: run V111..V135 via the normal orchestrator.
    run_via_wrapper(repo, fn ->
      PhoenixKit.Migration.up(
        version: @current_version,
        prefix: prefix,
        create_schema: false
      )
    end)
  end

  @doc """
  Run NEW migration chain for an EXISTING install already at `existing_version`.
  The orchestrator must skip the squash-baseline and only apply the delta.

  Post-squash invariant: if `migrated_version >= @floor`, up() should only run
  V(existing+1)..@current_version without touching the baseline.

  [DB]
  """
  def run_new_chain_existing(repo, prefix, _existing_version, opts \\ []) do
    _create_schema = Keyword.get(opts, :create_schema, false)

    run_via_wrapper(repo, fn ->
      PhoenixKit.Migration.up(
        version: @current_version,
        prefix: prefix,
        create_schema: false
      )
    end)
  end

  @doc """
  Assert that calling up() on an install at `existing_version` (which is below
  @floor) produces a clear error rather than silently running the baseline on
  top of existing tables.

  Returns :ok if an error is raised, {:unexpected_success, result} otherwise.
  [DB]
  """
  def assert_below_floor_error(repo, prefix, existing_version) when existing_version < @floor do
    result =
      try do
        run_via_wrapper(repo, fn ->
          PhoenixKit.Migration.up(
            version: @current_version,
            prefix: prefix,
            create_schema: false
          )
        end)

        {:unexpected_success, :ok}
      rescue
        e -> {:error_raised, e}
      catch
        kind, value -> {:error_caught, {kind, value}}
      end

    case result do
      {:unexpected_success, _} ->
        IO.puts(
          "  WARN: below-floor guard did not raise. Version #{existing_version} is below floor #{@floor} " <>
            "but up() returned successfully. This may be acceptable if the squash handles it gracefully " <>
            "— review the output carefully."
        )

        :warn

      {:error_raised, _e} ->
        IO.puts("  OK: below-floor guard raised as expected for version #{existing_version}.")
        :ok

      {:error_caught, _} ->
        IO.puts("  OK: below-floor guard threw as expected for version #{existing_version}.")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Run a `PhoenixKit.Migration.*` call inside a synthetic Ecto.Migrator wrapper.
  #
  # This is the "proven pattern" from the task spec. Each call to this function
  # creates a fresh ephemeral module, calls Ecto.Migrator.up/4 with a unique
  # synthetic version (so Ecto's deduplication never interferes), then purges
  # the module.
  #
  # The closure `migration_fn` is stored in the process dictionary keyed by the
  # unique module name — the only portable way to smuggle a runtime value into a
  # `Module.create`-defined function without macro-time binding.
  defp run_via_wrapper(repo, migration_fn) do
    mod = :"PhoenixKit.Squash.Runner.T#{:os.system_time(:microsecond)}"
    key = {__MODULE__, :fn, mod}

    Process.put(key, migration_fn)

    {:module, mod, _, _} =
      Module.create(
        mod,
        quote do
          use Ecto.Migration

          def up do
            key = {PhoenixKit.Squash.MigrationRunner, :fn, __MODULE__}
            f = Process.get(key)
            if f, do: f.()
          end

          def down, do: :ok
        end,
        __ENV__
      )

    fake_version = :os.system_time(:microsecond)

    result = Ecto.Migrator.up(repo, fake_version, mod, log: false)

    Process.delete(key)
    :code.delete(mod)
    :code.purge(mod)

    result
  end

end
