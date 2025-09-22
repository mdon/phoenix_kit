defmodule PhoenixKit.Migrations.Postgres.V11 do
  @moduledoc """
  PhoenixKit V11 Migration: Per-User Timezone Settings

  This migration adds individual timezone preferences for each user, separate from
  the global system timezone setting. This allows personalized date/time formatting
  in admin interfaces and user experiences.

  ## Changes

  ### User Timezone Column
  - Adds user_timezone column to phoenix_kit_users table
  - Stores timezone offset as string (e.g., "-5", "0", "+8")
  - Nullable field with fallback to system timezone setting
  - Validates timezone range (-12 to +12)

  ### New Features
  - **Personal Timezone Preferences**: Each user can set their own timezone
  - **Admin Dashboard Enhancement**: Dates formatted per user's timezone
  - **Fallback System**: User timezone → System timezone → UTC
  - **Backward Compatible**: Existing users default to system timezone
  - **Settings Integration**: Seamless integration with existing settings UI

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Uses string type for timezone offset storage (consistent with global setting)
  - No additional indexes needed (lightweight personal preference)
  - Safe nullable field addition (no data migration required)
  """
  use Ecto.Migration

  @doc """
  Run the V11 migration to add per-user timezone settings.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add user_timezone column to existing phoenix_kit_users table
    alter table(:phoenix_kit_users, prefix: prefix) do
      # Personal timezone offset (stored as string like global setting)
      # Examples: "-12", "-5", "0", "+8", "+12"
      # Null means fallback to system timezone setting
      add :user_timezone, :string, size: 3, null: true
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '11'"
  end

  @doc """
  Rollback the V11 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove user_timezone column from users table
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :user_timezone
    end

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '10'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end