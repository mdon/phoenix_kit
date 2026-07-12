defmodule PhoenixKit.Migrations.Postgres.Helpers do
  @moduledoc """
  Shared SQL helpers for the versioned Postgres migration chain.

  Centralizes the prefix-sensitive patterns that individual version
  modules used to hand-roll (and get subtly wrong in independent ways):

    * `qualify_table/2` — schema-qualified table reference for raw SQL.
      Index **names** must stay bare on `CREATE INDEX` (Postgres rejects
      `CREATE INDEX schema.name`); only `DROP INDEX schema.name` accepts
      a qualified name.
    * `validate_prefix!/1` — rejects prefixes that can't be interpolated
      into SQL safely. Called at the `up/down` entry points.
    * `ensure_extension!/1` — privilege-aware replacement for a bare
      `CREATE EXTENSION IF NOT EXISTS`. Postgres checks the CREATE
      privilege *before* the IF-NOT-EXISTS short-circuit, so the bare
      statement fails for low-privilege roles even when the extension is
      already installed. This helper checks `pg_extension` first and
      only attempts creation when the extension is genuinely missing.
    * `ensure_uuid_v7_function/1` — creates `uuid_generate_v7()` inside
      the install's schema (never wherever `search_path` happens to
      point, which pollutes `public` and fails outright on PG15+ where
      `public` isn't world-writable).

  Functions without a `repo` argument run in `Ecto.Migration` context
  (immediate existence checks via `repo().query/3`, DDL queued via
  `execute/1`). The `repo`-taking variants are for runtime callers such
  as `PhoenixKit.Migrations.UUIDRepair`.
  """

  @prefix_format ~r/^[a-z_][a-z0-9_]*$/

  @required_extensions %{
    "citext" => "case-insensitive email storage (V01)",
    "pgcrypto" => "UUIDv7 generation via gen_random_bytes (V26/V40)",
    "pg_trgm" => "trigram search on PDF page content (V111)"
  }

  @uuid_v7_function_body """
  RETURNS uuid AS $$
  DECLARE
    unix_ts_ms bytea;
    uuid_bytes bytea;
  BEGIN
    -- Get current timestamp in milliseconds
    unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);

    -- Build UUIDv7: 6 bytes timestamp + 2 bytes random (with version) + 8 bytes random (with variant)
    uuid_bytes := unix_ts_ms || gen_random_bytes(10);

    -- Set version 7 (0111xxxx in byte 7)
    uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);

    -- Set variant (10xxxxxx in byte 9)
    uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);

    RETURN encode(uuid_bytes, 'hex')::uuid;
  END
  $$ LANGUAGE plpgsql VOLATILE;
  """

  @doc """
  Schema-qualified table reference for raw SQL interpolation.

  `nil` and `"public"` both qualify explicitly as `public.` — an
  explicit schema never depends on the connection's `search_path`.
  """
  @spec qualify_table(String.t() | atom(), String.t() | nil) :: String.t()
  def qualify_table(table, nil), do: "public.#{table}"
  def qualify_table(table, prefix), do: "#{prefix}.#{table}"

  @doc """
  Schema-qualified `uuid_generate_v7()` call for SQL interpolation.
  """
  @spec uuid_v7_call(String.t() | nil) :: String.t()
  def uuid_v7_call(prefix), do: "#{schema(prefix)}.uuid_generate_v7()"

  @doc """
  Validates a schema prefix before it is interpolated into SQL.

  The migration chain interpolates the prefix into hundreds of
  statements, mostly unquoted, so only conventional lower-case
  identifiers are supported: `#{inspect(@prefix_format.source)}`.
  Raises `ArgumentError` for anything else (including uppercase or
  dashed names, which only ever half-worked).
  """
  @spec validate_prefix!(term()) :: :ok
  def validate_prefix!(prefix) when is_binary(prefix) do
    if Regex.match?(@prefix_format, prefix) do
      :ok
    else
      raise ArgumentError, """
      invalid PhoenixKit schema prefix: #{inspect(prefix)}

      The prefix is interpolated into SQL identifiers, so it must match
      #{inspect(@prefix_format.source)} (lower-case letters, digits and
      underscores, not starting with a digit) — e.g. "auth" or "my_app".
      """
    end
  end

  def validate_prefix!(prefix) do
    raise ArgumentError,
          "invalid PhoenixKit schema prefix: expected a string, got #{inspect(prefix)}"
  end

  @doc """
  Ensures a Postgres extension is available, in migration context.

  * already installed → no-op (skips the `CREATE EXTENSION` privilege
    check entirely, so pre-provisioned low-privilege setups pass)
  * missing + role can create → queues `CREATE EXTENSION IF NOT EXISTS`
  * missing + role cannot create → raises an operator-facing error
    listing the extensions to pre-create as a privileged role
  """
  @spec ensure_extension!(String.t()) :: :ok
  def ensure_extension!(name) do
    do_ensure_extension!(Ecto.Migration.repo(), name, &Ecto.Migration.execute/1)
  end

  @doc """
  Runtime variant of `ensure_extension!/1` for callers outside migration
  context (statements run immediately on `repo`).
  """
  @spec ensure_extension!(Ecto.Repo.t(), String.t()) :: :ok
  def ensure_extension!(repo, name) do
    do_ensure_extension!(repo, name, fn sql -> repo.query!(sql, [], log: false) end)
  end

  @doc """
  Ensures `uuid_generate_v7()` exists in the install's schema, in
  migration context.

  Checks `pg_proc` first (so an existing function — possibly owned by a
  different role — is never re-created) and queues a schema-qualified
  `CREATE OR REPLACE FUNCTION` only when missing. The schema must exist
  when this runs; V01 owns schema creation, so callers on the upgrade
  path (installed version > 0) are always safe.
  """
  @spec ensure_uuid_v7_function(String.t() | nil) :: :ok
  def ensure_uuid_v7_function(prefix) do
    do_ensure_uuid_v7_function(Ecto.Migration.repo(), prefix, &Ecto.Migration.execute/1)
  end

  @doc """
  Runtime variant of `ensure_uuid_v7_function/1` (statements run
  immediately on `repo`).
  """
  @spec ensure_uuid_v7_function(Ecto.Repo.t(), String.t() | nil) :: :ok
  def ensure_uuid_v7_function(repo, prefix) do
    do_ensure_uuid_v7_function(repo, prefix, fn sql -> repo.query!(sql, [], log: false) end)
  end

  defp do_ensure_uuid_v7_function(repo, prefix, executor) do
    unless uuid_v7_function_exists?(repo, prefix) do
      executor.("""
      CREATE OR REPLACE FUNCTION #{schema(prefix)}.uuid_generate_v7()
      #{@uuid_v7_function_body}
      """)
    end

    :ok
  end

  defp uuid_v7_function_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE p.proname = 'uuid_generate_v7'
      AND n.nspname = $1
    )
    """

    case repo.query(query, [schema(prefix)], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp do_ensure_extension!(repo, name, executor) do
    cond do
      extension_exists?(repo, name) ->
        :ok

      can_create_extension?(repo) ->
        executor.("CREATE EXTENSION IF NOT EXISTS #{name}")
        :ok

      true ->
        raise """
        PhoenixKit requires the Postgres extension '#{name}', which is not
        installed, and the current database role cannot create it.

        Pre-create the required extensions as a privileged role:

        #{Enum.map_join(@required_extensions, "\n", fn {ext, why} -> "    CREATE EXTENSION IF NOT EXISTS #{ext};  -- #{why}" end)}

        then re-run the migration.
        """
    end
  end

  defp extension_exists?(repo, name) do
    case repo.query("SELECT 1 FROM pg_extension WHERE extname = $1", [name], log: false) do
      {:ok, %{num_rows: rows}} -> rows > 0
      _ -> false
    end
  end

  # Trusted extensions (citext/pgcrypto/pg_trgm on PG13+) need CREATE on
  # the current database; superusers can always create. When in doubt
  # (query failure), report "can create" so the original CREATE EXTENSION
  # path — and its native error message — is preserved.
  defp can_create_extension?(repo) do
    query = """
    SELECT rolsuper OR has_database_privilege(current_database(), 'CREATE')
    FROM pg_roles WHERE rolname = current_user
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[allowed]]}} -> allowed == true
      _ -> true
    end
  end

  defp schema(nil), do: "public"
  defp schema(prefix), do: prefix
end
