defmodule PhoenixKit.RepoHelper do
  @moduledoc """
  Helper for dynamically resolving the repository to use.

  This module provides functions to get the appropriate repository
  based on configuration. It will use the configured repo from
  the parent application if available, otherwise fall back to
  the built-in PhoenixKit.Repo for development/testing.
  """

  alias PhoenixKit.Config

  @doc """
  Gets the repository module to use.

  Expects repo to be configured via PhoenixKit.Config.get(:repo).
  Raises an error if no repo is configured.
  """
  def repo do
    case Config.get(:repo, nil) do
      nil ->
        raise """
        No repository configured for PhoenixKit.

        Please configure a repository in your application:

            config :phoenix_kit, repo: MyApp.Repo
        """

      repo when is_atom(repo) ->
        repo
    end
  end

  @doc """
  Delegates to the configured repo's get_by function.
  """
  def get_by(queryable, clauses, opts \\ []) do
    repo().get_by(queryable, clauses, opts)
  end

  @doc """
  Delegates to the configured repo's get function.
  """
  def get(queryable, id, opts \\ []) do
    repo().get(queryable, id, opts)
  end

  @doc """
  Delegates to the configured repo's get! function.
  """
  def get!(queryable, id, opts \\ []) do
    repo().get!(queryable, id, opts)
  end

  @doc """
  Delegates to the configured repo's all function.
  """
  def all(queryable, opts \\ []) do
    repo().all(queryable, opts)
  end

  @doc """
  Delegates to the configured repo's one function.
  """
  def one(queryable, opts \\ []) do
    repo().one(queryable, opts)
  end

  @doc """
  Delegates to the configured repo's insert function.
  """
  def insert(struct_or_changeset, opts \\ []) do
    repo().insert(struct_or_changeset, opts)
  end

  @doc """
  Delegates to the configured repo's insert! function.
  """
  def insert!(struct_or_changeset, opts \\ []) do
    repo().insert!(struct_or_changeset, opts)
  end

  @doc """
  Delegates to the configured repo's update function.
  """
  def update(changeset, opts \\ []) do
    repo().update(changeset, opts)
  end

  @doc """
  Delegates to the configured repo's delete function.
  """
  def delete(struct_or_changeset, opts \\ []) do
    repo().delete(struct_or_changeset, opts)
  end

  @doc """
  Delegates to the configured repo's delete_all function.
  """
  def delete_all(queryable, opts \\ []) do
    repo().delete_all(queryable, opts)
  end

  @doc """
  Delegates to the configured repo's exists? function.
  """
  def exists?(queryable, opts \\ []) do
    repo().exists?(queryable, opts)
  end

  @doc """
  Delegates to the configured repo's aggregate function.
  """
  def aggregate(queryable, aggregate, field, opts \\ []) do
    repo().aggregate(queryable, aggregate, field, opts)
  end

  @doc """
  Delegates to the configured repo's query function.
  """
  def query(sql, params \\ [], opts \\ []) do
    repo().query(sql, params, opts)
  end

  @doc """
  Delegates to the configured repo's query! function.
  """
  def query!(sql, params \\ [], opts \\ []) do
    repo().query!(sql, params, opts)
  end

  @doc """
  Returns the primary key column name for a given table.

  Looks up the table's primary key by querying `pg_index`. Uses Postgres'
  `to_regclass/1` so the table name can be passed as a bind parameter
  (search-path aware, returns NULL when the table doesn't exist) — Postgrex
  can't bind a text parameter to a `regclass` cast directly.

  ## Returns

    * `column_name :: String.t()` when the table has a single-column primary key.

  ## Raises

    * `ArgumentError` when the table doesn't exist, has no primary key, or
      has a composite primary key (this helper only supports single-column
      PKs; callers building `ON CONFLICT` clauses must handle composite PKs
      explicitly).
    * Any error raised by the underlying repo query (e.g. `Postgrex.Error`).

  Previously this function silently returned `"id"` on any failure, which
  masked the fact that every shipped PhoenixKit schema uses `uuid` as its
  primary key — see issue #517.
  """
  def get_pk_column(table_name) when is_binary(table_name) do
    sql = """
    SELECT a.attname
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = to_regclass($1)
    AND i.indisprimary
    """

    case query(sql, [table_name]) do
      {:ok, %{rows: [[col]]}} ->
        col

      {:ok, %{rows: []}} ->
        raise ArgumentError,
              "no primary key found for table #{inspect(table_name)} " <>
                "(table doesn't exist or has no primary key)"

      {:ok, %{rows: rows}} ->
        cols = Enum.map(rows, fn [c] -> c end)

        raise ArgumentError,
              "table #{inspect(table_name)} has a composite primary key " <>
                "(#{Enum.join(cols, ", ")}); get_pk_column/1 only supports single-column PKs"

      {:error, reason} ->
        raise "failed to look up primary key for #{inspect(table_name)}: #{inspect(reason)}"
    end
  end

  @doc """
  Delegates to the configured repo's transaction function.
  """
  def transaction(fun_or_multi, opts \\ []) do
    repo().transaction(fun_or_multi, opts)
  end

  @doc """
  Delegates to the configured repo's preload function.
  """
  def preload(struct_or_structs, preloads, opts \\ []) do
    repo().preload(struct_or_structs, preloads, opts)
  end

  @doc """
  Delegates to the configured repo's rollback function.

  This function is used within transactions to rollback and return an error value.
  """
  def rollback(value) do
    repo().rollback(value)
  end
end
