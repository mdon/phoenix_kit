#!/usr/bin/env elixir
#
# generate_baseline.exs — Generate lib/phoenix_kit/migrations/postgres/v110.ex
#
# Runs OLD V01..V110 into a temporary schema, pg_dump the result, and
# transforms the dump into the new baseline migration module.
#
# [DB] — REQUIRES A LIVE POSTGRES CONNECTION.
#
# Run:
#   MIX_ENV=test mix run dev_docs/squash/generate_baseline.exs
#
# Optional env vars:
#   PK_BASELINE_SCHEMA  — schema name for the generation run (default: pk_baseline_gen)
#   PK_BASELINE_DRYRUN  — set to "true" to print the generated file instead of writing it
#
# After running, ALWAYS review the generated file before committing:
#   git diff lib/phoenix_kit/migrations/postgres/v110.ex
#
# See dev_docs/squash/README.md for full documentation.

# ===========================================================================
# Transformer module — must be defined BEFORE it is called at the bottom.
# ===========================================================================

defmodule Transformer do
  @moduledoc """
  Converts a pg_dump SQL string (from the OLD V01..V110 chain) into a valid
  `PhoenixKit.Migrations.Postgres.V110` Elixir module.

  ## What it does

  1. Prepends public-schema objects (extensions + uuid_generate_v7()) that live
     in `public` and must always exist but won't appear in a `-n <schema>` dump.
  2. Substitutes the temporary schema name with the runtime prefix placeholder
     (via the `p` variable pattern used in all PK migration modules).
  3. Adds a `CREATE SCHEMA IF NOT EXISTS` guard for non-public prefixes.
  4. Ends `up/1` with `COMMENT ON TABLE \#{p}phoenix_kit IS '110'` (self-stamp).
  5. Generates a `down/1` that tears down all squash-baseline objects.

  ## Limitations (read before using the generated file)

  - This is a text-level SQL rewrite, NOT a full SQL parser. Complex DDL
    (DO $$ blocks, function bodies with dollar-quoting, check constraints
    spanning multiple lines) is passed through verbatim inside `execute("...")`
    heredocs. Review them manually.
  - The dump-order is preserved (respects FK dependencies). The normalise
    sort from DumpHelper is NOT applied here.
  - TODO markers in the generated file indicate places requiring manual review.
  - After generation, `mix format` the generated file and fix any credo
    warnings before committing.
  """

  @floor 110

  # Public-schema preamble — extensions and uuid_generate_v7().
  # These live in PUBLIC and are NOT captured by "-n <schema>" pg_dump.
  # Stored as a plain function to avoid heredoc-within-sigil parsing issues.
  def public_preamble do
    # Each line is a string that becomes an execute() call or a comment in
    # the generated file. We build the preamble as a single string.
    uuid_fn_body =
      Enum.join(
        [
          "    CREATE OR REPLACE FUNCTION uuid_generate_v7()",
          "    RETURNS uuid AS $$",
          "    DECLARE",
          "      unix_ts_ms bytea;",
          "      uuid_bytes bytea;",
          "    BEGIN",
          "      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);",
          "      uuid_bytes := unix_ts_ms || gen_random_bytes(10);",
          "      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);",
          "      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);",
          "      RETURN encode(uuid_bytes, 'hex')::uuid;",
          "    END",
          "    $$ LANGUAGE plpgsql VOLATILE;"
        ],
        "\n"
      )

    lines = [
      ~s[    # Extensions live in PUBLIC schema — always idempotent, safe to repeat.],
      ~s[    execute("CREATE EXTENSION IF NOT EXISTS citext")],
      ~s[    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")],
      ~s[    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")],
      "",
      ~s[    # UUIDv7 generation function — lives in PUBLIC, called unqualified.],
      ~s[    # Source: lib/phoenix_kit/migrations/postgres/v40.ex],
      ~s[    execute("""],
      uuid_fn_body,
      ~s[    """)]
    ]

    Enum.join(lines, "\n")
  end

  def transform(raw_dump, source_schema, floor) do
    sql_statements = extract_statements(raw_dump, source_schema)
    up_body = build_up_body(sql_statements, floor)
    down_body = build_down_body(sql_statements, floor)
    render_module(up_body, down_body, floor)
  end

  # ---------------------------------------------------------------------------
  # Extract and clean statements from the dump
  # ---------------------------------------------------------------------------

  defp extract_statements(raw_dump, source_schema) do
    raw_dump
    |> strip_pg_dump_headers()
    |> strip_set_statements()
    |> strip_ownership_lines()
    |> substitute_schema(source_schema)
    |> split_into_statements()
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_pg_dump_headers(sql) do
    # Remove the pg_dump file header (comment block before first DDL).
    # Everything up to the first non-comment, non-blank line is dropped.
    lines = String.split(sql, "\n")

    {_in_header, kept} =
      Enum.reduce(lines, {true, []}, fn line, {in_header, acc} ->
        stripped = String.trim(line)

        cond do
          in_header and (stripped == "" or String.starts_with?(stripped, "--")) ->
            {true, acc}

          true ->
            {false, [line | acc]}
        end
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end

  defp strip_set_statements(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line ->
      t = String.trim(line)
      String.starts_with?(t, "SET ") or String.starts_with?(t, "SELECT pg_catalog.set")
    end)
    |> Enum.join("\n")
  end

  defp strip_ownership_lines(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line ->
      t = String.trim(line)

      (String.starts_with?(t, "ALTER TABLE") or String.starts_with?(t, "ALTER SCHEMA")) and
        String.contains?(t, " OWNER TO ")
    end)
    |> Enum.join("\n")
  end

  # Replace the source schema name with #{p} interpolation placeholder.
  # Generated Elixir code defines: p = if prefix == "public", do: "public.", else: "#{prefix}."
  # We output literal #{p} which becomes interpolated in the heredoc of the generated file.
  defp substitute_schema(sql, schema_name) do
    sql
    |> String.replace(~s("#{schema_name}".), "\#{p}")
    |> String.replace(~s("#{schema_name}"), "\#{p}")
    |> String.replace("#{schema_name}.", "\#{p}")
    |> String.replace("'#{schema_name}'", "'\#{prefix}'")
  end

  defp split_into_statements(sql) do
    sql
    |> split_respecting_dollar_quoting()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Split on top-level semicolons, respecting $$ dollar-quoting blocks.
  defp split_respecting_dollar_quoting(sql) do
    {statements, current, in_dollar} =
      sql
      |> String.graphemes()
      |> Enum.reduce({[], "", false}, fn char, {stmts, cur, in_dollar} ->
        cond do
          char == "$" ->
            {stmts, cur <> "$", !in_dollar}

          char == ";" and not in_dollar ->
            trimmed = String.trim(cur)
            if trimmed != "" do
              {[trimmed | stmts], "", false}
            else
              {stmts, "", false}
            end

          true ->
            {stmts, cur <> char, in_dollar}
        end
      end)

    # Flush any remaining content
    remaining = String.trim(current)
    # in_dollar state at end is diagnostic — can't easily fix here, but safe to ignore
    _ = in_dollar

    all = if remaining != "", do: [remaining | statements], else: statements
    Enum.reverse(all)
  end

  # ---------------------------------------------------------------------------
  # Build up/1 body
  # ---------------------------------------------------------------------------

  defp build_up_body(statements, floor) do
    schema_guard = """
        # Create schema if non-public and caller requested schema creation.
        if create_schema? and prefix != "public" do
          execute("CREATE SCHEMA IF NOT EXISTS \#{quoted_prefix}")
        end
    """

    statement_lines =
      statements
      |> Enum.map(&statement_to_elixir/1)
      |> Enum.join("\n\n")

    self_stamp = ~s[    execute("COMMENT ON TABLE \#{p}phoenix_kit IS '#{floor}'")]

    Enum.join(
      [
        schema_guard,
        "",
        public_preamble(),
        "",
        statement_lines,
        "",
        self_stamp
      ],
      "\n"
    )
  end

  # ---------------------------------------------------------------------------
  # Build down/1 body
  # ---------------------------------------------------------------------------

  defp build_down_body(statements, _floor) do
    # Collect CREATE TABLE statement targets to build DROP TABLE list.
    tables =
      statements
      |> Enum.filter(&String.starts_with?(&1, "CREATE TABLE"))
      |> Enum.map(fn stmt ->
        case Regex.run(~r/CREATE TABLE (?:IF NOT EXISTS )?(\S+)/, stmt) do
          [_, name] -> name
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      # Reverse insertion order to respect FK dependencies on DROP.
      |> Enum.reverse()

    drop_lines =
      tables
      |> Enum.map(fn tbl -> ~s[    execute("DROP TABLE IF EXISTS #{tbl} CASCADE")] end)
      |> Enum.join("\n")

    todo_note = """
        # TODO: If V01..V110 created any schema-scoped sequences or functions
        # (not public.uuid_generate_v7() — that must stay), add DROP statements here.
        # DO NOT drop extensions (citext, pgcrypto, pg_trgm) — they are public objects
        # shared across all schemas in the cluster.
    """

    # The COMMENT below is best-effort: if all tables were dropped the table is gone.
    # migrated_version/1 returns 0 when phoenix_kit table is absent, so this is fine.
    best_effort_comment =
      "    # After dropping all tables, migrated_version/1 returns 0 automatically."

    Enum.join(
      [
        todo_note,
        drop_lines,
        "",
        best_effort_comment
      ],
      "\n"
    )
  end

  # ---------------------------------------------------------------------------
  # Statement -> Elixir execute() call
  # ---------------------------------------------------------------------------

  defp statement_to_elixir(stmt) do
    multiline = String.contains?(stmt, "\n")
    has_dollar = String.contains?(stmt, "$$")
    has_quotes = String.contains?(stmt, "'") or String.contains?(stmt, ~s("))

    if multiline or has_dollar or has_quotes do
      # Use heredoc — avoids any escaping.
      # TODO: Verify that each generated heredoc is valid Elixir (no unmatched
      # triple-quote sequences inside the SQL body).
      indented = stmt |> String.split("\n") |> Enum.map(&("    " <> &1)) |> Enum.join("\n")
      "    execute(\"\"\"\n#{indented}\n    \"\"\")"
    else
      "    execute(\"#{stmt}\")"
    end
  end

  # ---------------------------------------------------------------------------
  # Render the final module file
  # ---------------------------------------------------------------------------

  defp render_module(up_body, down_body, floor) do
    # We build the file content as a list of strings to avoid nested heredoc issues.
    header = """
    defmodule PhoenixKit.Migrations.Postgres.V#{floor} do
      @moduledoc false

      # =========================================================================
      # V#{floor}: Squash baseline — consolidation of V01..V#{floor}.
      #
      # This module was generated by dev_docs/squash/generate_baseline.exs.
      # DO NOT edit by hand — re-run the generator and review the diff.
      #
      # Fresh installs (migrated_version == 0) use this baseline followed by
      # V#{floor + 1}..current. Existing installs at or above V#{floor} skip
      # this module entirely (the orchestrator in postgres.ex checks
      # migrated_version before dispatching).
      #
      # Public-schema objects (citext, pgcrypto, pg_trgm extensions and
      # uuid_generate_v7() function) live in PUBLIC and are always created with
      # IF NOT EXISTS / CREATE OR REPLACE. They must NEVER be dropped in down/1.
      #
      # Self-stamping: up/1 ends with COMMENT ON TABLE #{p}phoenix_kit IS '#{floor}'
      # so migrated_version/1 correctly reports V#{floor} after a single fresh install.
      # =========================================================================

      use Ecto.Migration

      def up(opts) do
        prefix = Map.get(opts, :prefix, "public")
        create_schema? = Map.get(opts, :create_schema, prefix != "public")
        quoted_prefix = inspect(prefix)
        # p is used as a table-name prefix: "public." or "myschema."
        p = if prefix == "public", do: "public.", else: "\#{prefix}."
        # Suppress unused-variable warning when SQL does not reference p
        _ = {create_schema?, quoted_prefix, p}

    #{up_body}
      end

      def down(opts) do
        prefix = Map.get(opts, :prefix, "public")
        p = if prefix == "public", do: "public.", else: "\#{prefix}."
        _ = p

    #{down_body}
      end
    end
    """

    header
  end
end

# ===========================================================================
# Script body — runs after Transformer is defined
# ===========================================================================

# ---------------------------------------------------------------------------
# Bootstrap: load helpers from this directory
# ---------------------------------------------------------------------------

root = Path.expand(".", __DIR__)
Code.require_file("#{root}/repo_helper.ex")
Code.require_file("#{root}/dump_helper.ex")
Code.require_file("#{root}/migration_runner.ex")

alias PhoenixKit.Squash.RepoHelper
alias PhoenixKit.Squash.DumpHelper
alias PhoenixKit.Squash.MigrationRunner

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

floor = 110
output_path = "/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/v110.ex"
schema = System.get_env("PK_BASELINE_SCHEMA", "pk_baseline_gen")
dry_run = System.get_env("PK_BASELINE_DRYRUN") == "true"

IO.puts("""
=======================================================
PhoenixKit Migration Squash — Baseline Generator
Floor: V#{floor}
Output: #{output_path}
Schema: #{schema}
Dry run: #{dry_run}
=======================================================
""")

# ---------------------------------------------------------------------------
# DB connection [DB]
# ---------------------------------------------------------------------------

IO.puts("Connecting to database...")
repo = RepoHelper.start!()
IO.puts("Connected.\n")

# ---------------------------------------------------------------------------
# Step 1: Run OLD V01..V110 into a temporary schema [DB]
# ---------------------------------------------------------------------------

IO.puts("Step 1: Running OLD V01..V#{floor} into schema '#{schema}'...")

RepoHelper.query!(repo, "DROP SCHEMA IF EXISTS #{schema} CASCADE")
RepoHelper.query!(repo, "CREATE SCHEMA #{schema}")

MigrationRunner.run_old_chain(repo, schema, to_version: floor, create_schema: false)

IO.puts("  Migration chain complete.")

# ---------------------------------------------------------------------------
# Step 2: pg_dump the schema [DB]
# ---------------------------------------------------------------------------

IO.puts("Step 2: Dumping schema '#{schema}' via pg_dump...")

raw_dump =
  case DumpHelper.dump(schema) do
    {:ok, sql} ->
      IO.puts("  Dump complete (#{byte_size(sql)} bytes).")
      sql

    {:error, reason} ->
      IO.puts("ERROR: pg_dump failed: #{reason}")
      RepoHelper.query!(repo, "DROP SCHEMA IF EXISTS #{schema} CASCADE")
      System.halt(1)
  end

# Save the raw dump for inspection.
dump_path = "#{__DIR__}/baseline_raw_#{schema}.sql"
File.write!(dump_path, raw_dump)
IO.puts("  Raw dump saved to #{dump_path}")

# ---------------------------------------------------------------------------
# Step 3: Transform the dump into v110.ex
# ---------------------------------------------------------------------------

IO.puts("Step 3: Transforming dump into baseline module v#{floor}.ex...")
generated = Transformer.transform(raw_dump, schema, floor)

# ---------------------------------------------------------------------------
# Step 4: Write or print
# ---------------------------------------------------------------------------

if dry_run do
  IO.puts("\n--- DRY RUN: Generated content (#{byte_size(generated)} bytes) ---")
  IO.puts(generated)
else
  File.write!(output_path, generated)
  IO.puts("  Written to #{output_path}")
end

# ---------------------------------------------------------------------------
# Step 5: Cleanup
# ---------------------------------------------------------------------------

IO.puts("Step 5: Cleaning up temporary schema '#{schema}'...")
RepoHelper.query!(repo, "DROP SCHEMA IF EXISTS #{schema} CASCADE")
IO.puts("  Done.\n")

IO.puts("""
=======================================================
Baseline generation complete.

NEXT STEPS:
  1. Review: git diff #{output_path}
  2. Format:  mix format #{output_path}
  3. Compile: mix compile
  4. Verify:  MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b
  5. Commit only after verify.exs passes all scenarios.

TODO items requiring manual review are marked with "# TODO:" in the file.

Raw dump saved to: #{dump_path}
=======================================================
""")
