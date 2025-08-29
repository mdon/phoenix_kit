defmodule PhoenixKit.Migrations.Postgres do
  @moduledoc false

  @behaviour PhoenixKit.Migration

  use Ecto.Migration

  alias Ecto.Adapters.SQL

  @initial_version 1
  @current_version 1
  @default_prefix "public"

  @doc false
  def initial_version, do: @initial_version

  @doc false
  def current_version, do: @current_version

  @impl PhoenixKit.Migration
  def up(opts) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  @impl PhoenixKit.Migration
  def down(opts) do
    # For down operations, don't set a default version - let target_version logic handle it
    opts = Enum.into(opts, %{prefix: @default_prefix})

    opts =
      opts
      |> Map.put(:quoted_prefix, inspect(opts.prefix))
      |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
      |> Map.put_new(:create_schema, opts.prefix != @default_prefix)

    current_version = migrated_version(opts)

    # Determine target version:
    # - If version not specified, rollback to complete removal (0)
    # - If version specified, rollback to that version
    target_version = Map.get(opts, :version, 0)

    if current_version > target_version do
      # For rollback from version N to version M, execute down for versions N, N-1, ..., M+1
      # This means we don't execute down for the target version itself
      change(current_version..(target_version + 1)//-1, :down, opts)
    end
  end

  @impl PhoenixKit.Migration
  def migrated_version(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # Use standard Ecto migration functions instead of direct queries
    # This will work correctly in migration context only
    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'phoenix_kit'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  @doc """
  Get current migrated version from database in runtime context (outside migrations).

  This function can be called from Mix tasks and other non-migration contexts.
  """
  def migrated_version_runtime(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'phoenix_kit'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    # Get repo from Application config (runtime context)
    repo = Application.get_env(:phoenix_kit, :repo)

    case repo do
      nil ->
        0

      repo ->
        # Start the parent application first to ensure repo is available
        app = get_repo_app(repo)

        if app do
          Application.ensure_all_started(app)
        end

        # Use Ecto.Adapters.SQL.query which should work now
        case SQL.query(repo, query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          {:ok, %{rows: []}} -> 0
          # Table exists but no version comment - assume version 1
          {:ok, %{rows: [[nil]]}} -> 1
          _ -> 0
        end
    end
  rescue
    _ -> 0
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0) do
    # Handle rollback to version 0 - tables are dropped, so we can't update comment
    # This is expected behavior for complete rollback
    :ok
  end

  defp record_version(%{prefix: prefix}, version) do
    # Use execute for migration context
    execute "COMMENT ON TABLE #{inspect(prefix)}.phoenix_kit IS '#{version}'"
  end

  # Get the application that owns the repo module
  defp get_repo_app(repo) do
    case :application.get_application(repo) do
      {:ok, app} ->
        app

      :undefined ->
        # Fallback: try to guess from module name
        [app_name | _] = Module.split(repo)
        String.to_atom(Macro.underscore(app_name))
    end
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
    |> Map.put_new(:create_schema, opts.prefix != @default_prefix)
  end
end
