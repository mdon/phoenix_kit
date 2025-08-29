defmodule PhoenixKit.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(%{create_schema: create?, prefix: prefix} = opts) do
    %{quoted_prefix: quoted} = opts

    # Only create schema if it's not 'public' and create_schema is true
    if create? && prefix != "public", do: execute("CREATE SCHEMA IF NOT EXISTS #{quoted}")

    # Create citext extension if not exists
    execute "CREATE EXTENSION IF NOT EXISTS citext"

    # Create version tracking table (phoenix_kit)
    create_if_not_exists table(:phoenix_kit, primary_key: false, prefix: prefix) do
      add :id, :serial, primary_key: true
      add :version, :integer, null: false
      add :migrated_at, :naive_datetime, null: false, default: fragment("NOW()")
    end

    create_if_not_exists unique_index(:phoenix_kit, [:version], prefix: prefix)

    # Create users table (phoenix_kit_users)
    create_if_not_exists table(:phoenix_kit_users, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :first_name, :string, size: 100
      add :last_name, :string, size: 100
      add :is_active, :boolean, default: true, null: false
      add :confirmed_at, :naive_datetime

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists unique_index(:phoenix_kit_users, [:email], prefix: prefix)

    # Create tokens table (phoenix_kit_users_tokens)
    create_if_not_exists table(:phoenix_kit_users_tokens, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true

      add :user_id, references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix),
        null: false

      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(updated_at: false, type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_users_tokens, [:user_id], prefix: prefix)

    create_if_not_exists unique_index(:phoenix_kit_users_tokens, [:context, :token],
                           prefix: prefix
                         )

    # Create user roles table (phoenix_kit_user_roles)
    create_if_not_exists table(:phoenix_kit_user_roles, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :name, :string, size: 50, null: false
      add :description, :text
      add :is_system_role, :boolean, default: false, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists unique_index(:phoenix_kit_user_roles, [:name], prefix: prefix)

    # Create user role assignments table (phoenix_kit_user_role_assignments)
    create_if_not_exists table(:phoenix_kit_user_role_assignments,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :id, :bigserial, primary_key: true

      add :user_id, references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix),
        null: false

      add :role_id, references(:phoenix_kit_user_roles, on_delete: :delete_all, prefix: prefix),
        null: false

      add :assigned_by, references(:phoenix_kit_users, on_delete: :nilify_all, prefix: prefix)
      add :assigned_at, :naive_datetime, null: false, default: fragment("NOW()")
      add :is_active, :boolean, default: true, null: false

      timestamps(updated_at: false, type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:role_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:assigned_by], prefix: prefix)

    create_if_not_exists unique_index(:phoenix_kit_user_role_assignments, [:user_id, :role_id],
                           prefix: prefix
                         )

    # Performance optimization indexes for active role queries
    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:user_id, :is_active],
                           prefix: prefix,
                           name: :idx_user_role_assignments_user_active
                         )

    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:role_id, :is_active],
                           prefix: prefix,
                           name: :idx_user_role_assignments_role_active
                         )

    create_if_not_exists index(:phoenix_kit_users, [:is_active],
                           prefix: prefix,
                           name: :idx_users_active
                         )

    # Insert system roles
    execute """
    INSERT INTO #{inspect(prefix)}.phoenix_kit_user_roles (name, description, is_system_role, inserted_at, updated_at)
    VALUES 
      ('Owner', 'System owner with full access', true, NOW(), NOW()),
      ('Admin', 'Administrator with elevated privileges', true, NOW(), NOW()),
      ('User', 'Standard user with basic access', true, NOW(), NOW())
    ON CONFLICT (name) DO NOTHING
    """

    # Role assignment is handled by Elixir application logic
    # The ensure_first_user_is_owner/1 function in PhoenixKit.Users.Roles
    # manages Owner/User role assignment with proper race condition protection
  end

  def down(%{prefix: prefix}) do
    # Drop tables in correct order (foreign key dependencies)
    drop_if_exists table(:phoenix_kit_user_role_assignments, prefix: prefix)
    drop_if_exists table(:phoenix_kit_user_roles, prefix: prefix)
    drop_if_exists table(:phoenix_kit_users_tokens, prefix: prefix)
    drop_if_exists table(:phoenix_kit_users, prefix: prefix)
    drop_if_exists table(:phoenix_kit, prefix: prefix)
  end
end
