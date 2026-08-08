defmodule Mix.Tasks.PhoenixKit.RepairUuid do
  @shortdoc "Repairs phoenix_kit tables whose uuid column is not a proper primary key"

  @moduledoc """
  Repairs `phoenix_kit_*` tables whose `uuid` column is the wrong type, nullable,
  or not the primary key.

  V163 performs this repair automatically during `mix ecto.migrate`, but skips
  any table large enough that the rewrite's `ACCESS EXCLUSIVE` lock would be an
  outage rather than a pause. This task is the deliberate, operator-chosen path
  for those — run it in a maintenance window.

      mix phoenix_kit.repair_uuid                       # every table that needs it
      mix phoenix_kit.repair_uuid phoenix_kit_email_events
      mix phoenix_kit.repair_uuid --dry-run             # show the SQL, change nothing
      mix phoenix_kit.repair_uuid --prefix tenant_a

  ## What it costs

  `ALTER COLUMN … TYPE uuid` rewrites the table and holds an `ACCESS EXCLUSIVE`
  lock for the duration — no reads, no writes, and behind a connection pooler
  that means the pool fills rather than merely waiting. There is no concurrent
  form of a type change; the size of the table is the size of the outage.

  The primary key is cheaper here than in the migration: outside a transaction
  the unique index is built `CONCURRENTLY` and then attached, so the exclusive
  lock covers only the attach. That is why this task is not simply "V163 without
  the limit".

  ## Safety

  Nothing is destructive except de-duplication, which deletes rows that share a
  uuid — on a table that has run without a primary key those are the same
  logical row stored twice, and a duplicate makes `ADD PRIMARY KEY` impossible.
  `--dry-run` prints every statement, including the delete, without executing.

  Values that cannot be cast to `uuid` abort that table with the query to
  inspect them; other tables still proceed.
  """

  use Mix.Task

  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Migrations.UUIDIntegrity

  @requirements ["app.start"]

  @switches [dry_run: :boolean, prefix: :string]

  @impl Mix.Task
  def run(args) do
    {opts, tables} = OptionParser.parse!(args, strict: @switches)

    # Same resolution the doctor and installer use: --prefix > app config > public
    prefix = PrefixConfig.resolve_prefix(opts)
    dry_run? = opts[:dry_run] || false
    repo = PhoenixKit.RepoHelper.repo()

    broken =
      repo
      |> UUIDIntegrity.broken_tables(prefix)
      |> filter_requested(tables)

    case broken do
      [] ->
        Mix.shell().info([:green, "✓ Every phoenix_kit table has a proper uuid primary key."])

      found ->
        Mix.shell().info("Tables needing repair: #{length(found)}")
        Enum.each(found, &repair(repo, prefix, &1, dry_run?))
        report(dry_run?)
    end
  end

  defp filter_requested(broken, []), do: broken

  defp filter_requested(broken, requested) do
    Enum.filter(broken, &(&1.name in requested))
  end

  defp repair(repo, prefix, %{name: name} = table, dry_run?) do
    qualified = UUIDIntegrity.qualify(prefix, name)

    if UUIDIntegrity.castable?(repo, qualified, table) do
      rows = UUIDIntegrity.estimated_rows(repo, prefix, name)
      Mix.shell().info([:cyan, "\n#{name}", :reset, " (~#{rows} rows) #{describe(table)}"])

      # concurrent_index: this task runs outside a transaction, so the unique
      # index can be built without holding the table against readers.
      qualified
      |> UUIDIntegrity.repair_statements(prefix, table, concurrent_index: true)
      |> Enum.each(&run_statement(repo, &1, dry_run?))
    else
      Mix.shell().error("""
      #{name}: uuid holds values that are not valid UUIDs — skipped. Inspect with:
        SELECT uuid FROM #{qualified}
         WHERE uuid IS NOT NULL AND uuid !~* '#{uuid_regex()}' LIMIT 20;
      """)
    end
  end

  defp run_statement(_repo, sql, true), do: Mix.shell().info(["  [dry-run] ", String.trim(sql)])

  defp run_statement(repo, sql, false) do
    Mix.shell().info(["  ", String.trim(sql)])
    repo.query!(sql, [], timeout: :infinity)
  end

  defp describe(%{type: type, nullable: nullable, has_pk: has_pk}) do
    [
      if(type != "uuid", do: "type=#{type}"),
      if(nullable, do: "nullable"),
      if(not has_pk, do: "no primary key")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp report(true) do
    Mix.shell().info([:yellow, "\nDry run — nothing was changed."])
  end

  defp report(false) do
    Mix.shell().info([:green, "\n✓ Repair complete. Re-run mix phoenix_kit.doctor to confirm."])
  end

  defp uuid_regex, do: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
end
