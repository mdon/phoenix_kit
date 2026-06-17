defmodule PhoenixKit.Squash.DumpHelper do
  @moduledoc """
  Runs pg_dump and normalises the output so two dumps from different schema
  names can be compared meaningfully.

  ## Normalisation steps

  1. Replace the actual schema name with the placeholder `__SCHEMA__`.
  2. Strip SET statements, COMMENT/ownership lines, and pg_dump headers.
  3. Stable-sort CREATE TABLE / CREATE INDEX / CREATE SEQUENCE / ALTER TABLE
     blocks so object order differences don't produce a false diff.
  4. Collapse multiple blank lines to one.

  The normalised output is deterministic for a given schema shape regardless
  of which schema name was used or which pg_dump version produced it.
  """

  alias PhoenixKit.Squash.RepoHelper

  @doc """
  Run pg_dump --schema-only for the given schema and return the raw SQL string.

  pg_dump is invoked over a DIRECT connection (PGHOST/PGPORT from env), which
  bypasses pgbouncer. This is required because pg_dump uses features (COPY,
  SET, pg_catalog queries) that pgbouncer blocks.

  [DB]
  """
  def dump(schema) do
    ce = RepoHelper.connection_env()

    env =
      [
        {"PGHOST", ce.host},
        {"PGPORT", to_string(ce.port)},
        {"PGUSER", ce.username},
        {"PGPASSWORD", ce.password},
        {"PGDATABASE", ce.database}
      ]
      |> Enum.reject(fn {_, v} -> v == "" end)

    args = [
      "--schema-only",
      "--no-owner",
      "--no-privileges",
      "--no-comments",
      "-n",
      schema,
      # Exclude schema_migrations — Ecto's version-tracking table is an
      # implementation detail, not part of the PhoenixKit schema shape.
      "--exclude-table=#{schema}.schema_migrations",
      ce.database
    ]

    case System.cmd("pg_dump", args, env: env, stderr_to_stdout: false) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        {:error, "pg_dump exited #{exit_code}: #{output}"}
    end
  end

  @doc """
  Same as dump/1 but raises on failure.
  [DB]
  """
  def dump!(schema) do
    case dump(schema) do
      {:ok, sql} -> sql
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Normalise a pg_dump SQL string for comparison.

  Accepts either a raw dump string or a path to a dump file.
  Returns a normalised string.
  """
  def normalise(sql, schema_name) when is_binary(sql) and is_binary(schema_name) do
    sql
    |> strip_headers()
    |> strip_set_statements()
    |> strip_comment_lines()
    |> substitute_schema(schema_name)
    |> sort_statements()
    |> collapse_blank_lines()
    |> String.trim()
  end

  @doc """
  Compare two dump strings (from different schemas) and return :equal or
  {:diff, left_lines, right_lines}.
  """
  def compare(dump_a, schema_a, dump_b, schema_b) do
    norm_a = normalise(dump_a, schema_a)
    norm_b = normalise(dump_b, schema_b)

    if norm_a == norm_b do
      :equal
    else
      lines_a = String.split(norm_a, "\n")
      lines_b = String.split(norm_b, "\n")
      {:diff, lines_a, lines_b}
    end
  end

  @doc """
  Write a unified diff between two normalised dumps to stdout.
  """
  def print_diff(dump_a, schema_a, dump_b, schema_b) do
    case compare(dump_a, schema_a, dump_b, schema_b) do
      :equal ->
        IO.puts("Dumps are identical (after normalisation).")

      {:diff, lines_a, lines_b} ->
        IO.puts("Dumps differ after normalisation.")
        IO.puts("--- #{schema_a}")
        IO.puts("+++ #{schema_b}")
        print_unified_diff(lines_a, lines_b)
    end
  end

  # ---------------------------------------------------------------------------
  # Private normalisation helpers
  # ---------------------------------------------------------------------------

  # Remove pg_dump header block (lines starting with "--" before any DDL)
  defp strip_headers(sql) do
    lines = String.split(sql, "\n")

    # Drop everything up to the first non-comment, non-blank line that is
    # not a SET statement, keeping blank lines that separate blocks.
    {_skipping, kept} =
      Enum.reduce(lines, {true, []}, fn line, {skipping, acc} ->
        stripped = String.trim(line)

        cond do
          skipping and (stripped == "" or String.starts_with?(stripped, "--")) ->
            {true, acc}

          true ->
            {false, [line | acc]}
        end
      end)

    kept
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # Remove SET statements (pg_dump emits many: client_encoding, search_path, etc.)
  defp strip_set_statements(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line ->
      stripped = String.trim(line)
      String.starts_with?(stripped, "SET ") or String.starts_with?(stripped, "SELECT pg_catalog.set")
    end)
    |> Enum.join("\n")
  end

  # Remove comment-only lines and ownership lines
  defp strip_comment_lines(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line ->
      stripped = String.trim(line)

      String.starts_with?(stripped, "--") or
        String.starts_with?(stripped, "ALTER TABLE") and String.contains?(stripped, " OWNER TO ") or
        String.starts_with?(stripped, "ALTER SCHEMA") and String.contains?(stripped, " OWNER TO ")
    end)
    |> Enum.join("\n")
  end

  # Replace all occurrences of the schema name with a stable placeholder.
  # Handles both quoted (`"myschema"`) and unquoted (`myschema.`) forms.
  defp substitute_schema(sql, schema_name) do
    placeholder = "__SCHEMA__"

    sql
    |> String.replace(~s("#{schema_name}"), ~s("#{placeholder}"))
    |> String.replace("#{schema_name}.", "#{placeholder}.")
    |> String.replace("'#{schema_name}'", "'#{placeholder}'")
  end

  # Split the dump into top-level statement blocks (separated by blank lines or
  # semicolons) and sort them lexicographically so object ordering differences
  # from pg_dump don't produce false diffs.
  #
  # Strategy: split on ";\n\n" boundaries, sort each block, rejoin.
  defp sort_statements(sql) do
    # Split on double-newline after a semicolon (canonical pg_dump block separator)
    blocks =
      sql
      |> String.split(~r/;\s*\n\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    blocks
    |> Enum.sort()
    |> Enum.join(";\n\n")
    |> then(fn s -> if String.ends_with?(s, ";"), do: s, else: s <> ";" end)
  end

  # Collapse runs of 2+ blank lines to a single blank line
  defp collapse_blank_lines(sql) do
    String.replace(sql, ~r/\n{3,}/, "\n\n")
  end

  # Very simple unified diff — not a full Myers diff but sufficient for
  # human review of the normalised output.
  defp print_unified_diff(lines_a, lines_b) do
    set_a = MapSet.new(Enum.with_index(lines_a))
    set_b = MapSet.new(Enum.with_index(lines_b))

    removed = MapSet.difference(set_a, set_b)
    added = MapSet.difference(set_b, set_a)

    unless MapSet.size(removed) == 0 do
      IO.puts("\nLines only in OLD:")
      removed |> Enum.sort_by(fn {_, i} -> i end) |> Enum.each(fn {l, _} -> IO.puts("- #{l}") end)
    end

    unless MapSet.size(added) == 0 do
      IO.puts("\nLines only in NEW:")
      added |> Enum.sort_by(fn {_, i} -> i end) |> Enum.each(fn {l, _} -> IO.puts("+ #{l}") end)
    end
  end
end
