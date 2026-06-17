defmodule PhoenixKit.Squash.RepoHelper do
  @moduledoc """
  Starts a minimal Ecto/Postgrex repo wired from environment variables at
  script runtime (outside the normal Mix/test config pipeline).

  Usage from a .exs script:

      Code.require_file("dev_docs/squash/repo_helper.ex")
      {:ok, repo} = PhoenixKit.Squash.RepoHelper.start()
      PhoenixKit.Squash.RepoHelper.query!(repo, "SELECT 1")

  The repo module is `PhoenixKit.Test.Repo` (already compiled in MIX_ENV=test)
  but its connection config is overridden from env so the squash scripts can
  point at a different host/database than the normal test DB.

  Required env vars:
    PGHOST, PGPORT, PGUSER, PGPASSWORD (or PGPASSFILE), PGDATABASE

  Optional:
    PGSSL  — set to "true" to enable SSL
  """

  @repo PhoenixKit.Test.Repo

  # -------------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------------

  @doc """
  Start the repo and return {:ok, repo_module} or {:error, reason}.
  Idempotent: safe to call multiple times.

  [DB] — requires a live Postgres connection.
  """
  def start do
    ensure_applications_started()

    config = build_config()

    Application.put_env(:phoenix_kit, @repo, config)

    case @repo.start_link(config) do
      {:ok, _pid} ->
        {:ok, @repo}

      {:error, {:already_started, _pid}} ->
        {:ok, @repo}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Same as start/0 but raises on failure.
  """
  def start! do
    case start() do
      {:ok, repo} -> repo
      {:error, reason} -> raise "Failed to start repo: #{inspect(reason)}"
    end
  end

  @doc """
  Execute raw SQL via the running repo. Returns {:ok, result} or {:error, reason}.
  [DB]
  """
  def query(repo, sql, params \\ []) do
    repo.query(sql, params)
  end

  @doc """
  Execute raw SQL and raise on failure.
  [DB]
  """
  def query!(repo, sql, params \\ []) do
    case repo.query(sql, params) do
      {:ok, result} -> result
      {:error, reason} -> raise "Query failed: #{inspect(reason)}\nSQL: #{sql}"
    end
  end

  @doc """
  Run Ecto.Migrator.up/4 for a single migration module at a synthetic version.
  This is the proven pattern from the task spec.

  [DB]
  """
  def run_migration_module(repo, migration_module, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    log = Keyword.get(opts, :log, false)

    # Each migration runner needs a unique fake version number so
    # Ecto.Migrator doesn't deduplicate them via schema_migrations.
    fake_version = :os.system_time(:microsecond)

    Ecto.Migrator.up(repo, fake_version, migration_module,
      prefix: prefix,
      log: log
    )
  end

  @doc """
  Build and return a connection keyword list from env vars (for use with
  Postgrex directly if needed, e.g. for pg_dump subprocess args).
  """
  def connection_env do
    %{
      host: env!("PGHOST"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: env!("PGUSER"),
      password: System.get_env("PGPASSWORD", ""),
      database: System.get_env("PGDATABASE", ""),
      ssl: System.get_env("PGSSL") == "true"
    }
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp build_config do
    ce = connection_env()

    [
      hostname: ce.host,
      port: ce.port,
      username: ce.username,
      password: ce.password,
      database: database_name(ce.database),
      ssl: ce.ssl,
      pool_size: 5,
      # Disable sandbox so scripts can run DDL outside a transaction
      pool: DBConnection.ConnectionPool,
      log: false
    ]
  end

  defp database_name(""), do: raise("PGDATABASE env var is required")
  defp database_name(db), do: db

  defp env!(name) do
    case System.get_env(name) do
      nil -> raise "Required env var #{name} is not set"
      value -> value
    end
  end

  defp ensure_applications_started do
    for app <- [:telemetry, :db_connection, :ecto, :postgrex] do
      Application.ensure_all_started(app)
    end
  end
end
