defmodule PhoenixKit.Migrations do
  @moduledoc false

  defdelegate up(opts \\ []), to: PhoenixKit.Migration
  defdelegate down(opts \\ []), to: PhoenixKit.Migration
end

defmodule PhoenixKit.Migration do
  @moduledoc """
  Migrations create and modify the database tables PhoenixKit needs to function.

  ## Usage

  To use migrations in your application you'll need to generate an `Ecto.Migration` that wraps
  calls to `PhoenixKit.Migration`:

  ```bash
  mix ecto.gen.migration add_phoenix_kit
  ```

  Open the generated migration in your editor and call the `up` and `down` functions on
  `PhoenixKit.Migration`:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPhoenixKit do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up()

    def down, do: PhoenixKit.Migrations.down()
  end
  ```

  This will run all of PhoenixKit's versioned migrations for your database.

  Now, run the migration to create the table:

  ```bash
  mix ecto.migrate
  ```

  Migrations between versions are idempotent. As new versions are released, you may need to run
  additional migrations. To do this, generate a new migration:

  ```bash
  mix ecto.gen.migration upgrade_phoenix_kit_to_v2
  ```

  Open the generated migration in your editor and call the `up` and `down` functions on
  `PhoenixKit.Migration`, passing a version number:

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradePhoenixKitToV2 do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(version: 2)

    def down, do: PhoenixKit.Migrations.down(version: 2)
  end
  ```

  ## Isolation with Prefixes

  PhoenixKit supports namespacing through PostgreSQL schemas, also called "prefixes" in Ecto. With
  prefixes your auth tables can reside outside of your primary schema (usually public) and you can
  have multiple separate auth systems.

  To use a prefix you first have to specify it within your migration:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPrefixedPhoenixKitTables do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(prefix: "auth")

    def down, do: PhoenixKit.Migrations.down(prefix: "auth")
  end
  ```

  The migration will create the "auth" schema and all tables within
  that schema. With the database migrated you'll then specify the prefix in your configuration:

  ```elixir
  config :phoenix_kit,
    prefix: "auth",
    ...
  ```

  In some cases, for example if your "auth" schema already exists and your database user in
  production doesn't have permissions to create a new schema, trying to create the schema from the
  migration will result in an error. In such situations, it may be useful to inhibit the creation
  of the "auth" schema:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPrefixedPhoenixKitTables do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(prefix: "auth", create_schema: false)

    def down, do: PhoenixKit.Migrations.down(prefix: "auth")
  end
  ```

  ## Migrating Without Ecto

  If your application uses something other than Ecto for migrations, be it an external system or
  another ORM, it may be helpful to create plain SQL migrations for PhoenixKit database schema changes.

  The simplest mechanism for obtaining the SQL changes is to create the migration locally and run
  `mix ecto.migrate --log-migrations-sql`. That will log all of the generated SQL, which you can
  then paste into your migration system of choice.
  """

  use Ecto.Migration

  @doc """
  Migrates storage up to the latest version.
  """
  @callback up(Keyword.t()) :: :ok

  @doc """
  Migrates storage down to the previous version.
  """
  @callback down(Keyword.t()) :: :ok

  @doc """
  Identifies the last migrated version.
  """
  @callback migrated_version(Keyword.t()) :: non_neg_integer()

  @doc """
  Run the `up` changes for all migrations between the initial version and the current version.

  ## Example

  Run all migrations up to the current version:

      PhoenixKit.Migration.up()

  Run migrations up to a specified version:

      PhoenixKit.Migration.up(version: 2)

  Run migrations in an alternate prefix:

      PhoenixKit.Migration.up(prefix: "auth")

  Run migrations in an alternate prefix but don't try to create the schema:

      PhoenixKit.Migration.up(prefix: "auth", create_schema: false)
  """
  def up(opts \\ []) when is_list(opts) do
    migrator().up(opts)
  end

  @doc """
  Run the `down` changes for all migrations between the current version and the initial version.

  ## Example

  Run all migrations from current version down to the first:

      PhoenixKit.Migration.down()

  Run migrations down to and including a specified version:

      PhoenixKit.Migration.down(version: 1)

  Run migrations in an alternate prefix:

      PhoenixKit.Migration.down(prefix: "auth")
  """
  def down(opts \\ []) when is_list(opts) do
    migrator().down(opts)
  end

  @doc """
  Check the latest version the database is migrated to.

  ## Example

      PhoenixKit.Migration.migrated_version()
  """
  def migrated_version(opts \\ []) when is_list(opts) do
    migrator().migrated_version(opts)
  end

  defp migrator do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres -> PhoenixKit.Migrations.Postgres
      Ecto.Adapters.SQLite3 -> PhoenixKit.Migrations.SQLite
      Ecto.Adapters.MyXQL -> PhoenixKit.Migrations.MyXQL
      _ -> Keyword.fetch!(repo().config(), :phoenix_kit_migrator)
    end
  end
end
