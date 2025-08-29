defmodule Mix.Tasks.PhoenixKit.Gen.Migration do
  use Mix.Task

  @moduledoc """
  Generate PhoenixKit migration in parent application.

  This task generates a new migration file with PhoenixKit tables
  that can be customized before running.

  ## Usage

      mix phoenix_kit.gen.migration

  ## Options

    * `--table-prefix` - Custom prefix for tables (default: "phoenix_kit")

  ## Examples

      # Generate with default phoenix_kit_users prefix
      mix phoenix_kit.gen.migration

      # Generate with custom prefix
      mix phoenix_kit.gen.migration --table-prefix users

  """
  @shortdoc "Generate PhoenixKit migration"

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)
    table_prefix = opts[:table_prefix] || "phoenix_kit"

    timestamp = generate_timestamp()
    filename = "#{timestamp}_create_#{table_prefix}_tables.exs"
    path = Path.join("priv/repo/migrations", filename)

    File.mkdir_p!("priv/repo/migrations")

    migration_content = generate_migration_content(table_prefix)
    File.write!(path, migration_content)

    IO.puts("✅ Generated migration: #{filename}")
    IO.puts("Run: mix ecto.migrate")
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [table_prefix: :string])
    opts
  end

  defp generate_timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
      [year, month, day, hour, minute, second]
    )
    |> to_string()
  end

  defp generate_migration_content(table_prefix) do
    module_name = Macro.camelize("create_#{table_prefix}_tables")
    # For default phoenix_kit prefix, use phoenix_kit_users/phoenix_kit_users_tokens
    # For custom prefixes, use prefix/prefix_tokens
    {users_table, tokens_table} =
      if table_prefix == "phoenix_kit" do
        {"phoenix_kit_users", "phoenix_kit_users_tokens"}
      else
        {table_prefix, "#{table_prefix}_tokens"}
      end

    """
    defmodule #{Mix.Phoenix.context_app()}.Repo.Migrations.#{module_name} do
      use Ecto.Migration

      def change do
        execute "CREATE EXTENSION IF NOT EXISTS citext", ""

        create table(:#{users_table}) do
          add :email, :citext, null: false
          add :hashed_password, :string, null: false
          add :confirmed_at, :naive_datetime

          timestamps()
        end

        create unique_index(:#{users_table}, [:email])

        create table(:#{tokens_table}) do
          add :user_id, references(:#{users_table}, on_delete: :delete_all), null: false
          add :token, :binary, null: false
          add :context, :string, null: false
          add :sent_to, :string

          timestamps(updated_at: false)
        end

        create index(:#{tokens_table}, [:user_id])
        create unique_index(:#{tokens_table}, [:context, :token])
      end
    end
    """
  end
end
