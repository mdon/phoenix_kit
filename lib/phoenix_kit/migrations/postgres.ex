defmodule PhoenixKit.Migrations.Postgres do
  @moduledoc false

  @behaviour PhoenixKit.Migration

  use Ecto.Migration

  alias Ecto.Adapters.SQL

  @initial_version 1
  @current_version 2
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

    # First check if phoenix_kit table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables 
      WHERE table_name = 'phoenix_kit'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, check for version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo().query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          # Table exists but no version comment - assume version 1 (legacy V01 installation)
          _ -> 1
        end

      {:ok, %{rows: [[false]]}} ->
        # Table doesn't exist - no PhoenixKit installed
        0

      _ ->
        0
    end
  end

  @doc """
  Get current migrated version from database in runtime context (outside migrations).

  This function can be called from Mix tasks and other non-migration contexts.
  """
  def migrated_version_runtime(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # Get repo from Application config (runtime context)
    repo = Application.get_env(:phoenix_kit, :repo)

    case repo do
      nil ->
        0

      repo ->
        # Use Mix.Ecto.ensure_repo to properly start the repo and its dependencies
        try do
          if Code.ensure_loaded?(Mix.Ecto) do
            Mix.Ecto.ensure_repo(repo, [])
          else
            # Fallback for cases where Mix.Ecto is not available
            app = get_repo_app(repo)

            if app do
              Application.ensure_all_started(app)
            end
          end
        rescue
          _ -> :ok
        end

        version = detect_version_by_schema(repo, escaped_prefix)
        version
    end
  rescue
    _ ->
      0
  end

  # Detect version by analyzing database schema
  defp detect_version_by_schema(repo, escaped_prefix) do
    # Check if main PhoenixKit tables exist
    tables_query = """
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = '#{escaped_prefix}'
    AND table_name IN ('phoenix_kit_users', 'phoenix_kit_user_roles', 'phoenix_kit_user_role_assignments')
    ORDER BY table_name
    """

    case SQL.query(repo, tables_query, [], log: false) do
      {:ok, %{rows: rows}} ->
        table_names = Enum.map(rows, fn [name] -> name end)

        cond do
          # No PhoenixKit tables found
          Enum.empty?(table_names) ->
            0

          # If phoenix_kit_users table exists, assume at least V01
          "phoenix_kit_users" in table_names ->
            determine_version_from_role_tables(table_names, repo, escaped_prefix)

          # Some other PhoenixKit tables found - assume V01
          true ->
            1
        end

      _ ->
        0
    end
  end

  # Helper function to determine version based on role assignment table presence
  defp determine_version_from_role_tables(table_names, repo, escaped_prefix) do
    if "phoenix_kit_user_role_assignments" in table_names do
      check_role_assignment_schema(repo, escaped_prefix)
    else
      1
    end
  end

  # Check role assignment table schema to determine V01 vs V02
  defp check_role_assignment_schema(repo, escaped_prefix) do
    # Check if is_active column exists in role assignments table
    column_query = """
    SELECT column_name 
    FROM information_schema.columns 
    WHERE table_schema = '#{escaped_prefix}' 
    AND table_name = 'phoenix_kit_user_role_assignments'
    AND column_name = 'is_active'
    """

    case SQL.query(repo, column_query, [], log: false) do
      {:ok, %{rows: [["is_active"]]}} ->
        # is_active column exists - this is V01
        1

      {:ok, %{rows: []}} ->
        # is_active column doesn't exist - this is V02 or later
        check_version_comment(repo, escaped_prefix)

      _ ->
        # Error or unexpected result - default to V01 for safety
        1
    end
  end

  # Check version comment as final step
  defp check_version_comment(repo, escaped_prefix) do
    version_query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'phoenix_kit'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case SQL.query(repo, version_query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) ->
        String.to_integer(version)

      _ ->
        # No version comment found, but schema suggests V02+ (no is_active column)
        2
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up ->
        # For up migrations, set version to the highest version applied
        record_version(opts, Enum.max(range))

      :down ->
        # For down migrations, let individual migration handle version comments
        # This prevents conflicts with version comments in migration down() functions
        :ok
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
