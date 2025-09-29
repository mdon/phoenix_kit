defmodule PhoenixKit.Migrations.Postgres.V12 do
  @moduledoc """
  PhoenixKit V12 Migration: JSON Settings Support

  This migration adds JSONB support to the settings system, enabling storage
  of complex structured data alongside traditional string-based settings.

  ## Changes

  ### Settings Table Enhancement
  - Adds value_json column to phoenix_kit_settings table
  - Uses PostgreSQL JSONB type for optimal performance and indexing
  - Nullable field maintains backward compatibility
  - Supports complex configuration objects and arrays

  ### New Features
  - **JSON Data Storage**: Store complex objects, arrays, and nested data
  - **Native JSONB Performance**: PostgreSQL's optimized JSONB operations
  - **Backward Compatible**: Existing string settings continue to work
  - **Dual Storage Model**: Settings can use either string OR JSON values
  - **Cache Integration**: JSON data cached efficiently with existing system

  ## PostgreSQL Support
  - Leverages PostgreSQL's native JSONB data type
  - Supports prefix for schema isolation
  - Optimal storage and query performance for JSON data
  - Safe nullable field addition (no data migration required)

  ## Usage Examples

      # Traditional string setting (unchanged)
      PhoenixKit.Settings.update_setting("theme", "dark")

      # New JSON setting
      config = %{
        "colors" => %{"primary" => "#3b82f6", "secondary" => "#64748b"},
        "features" => ["dark_mode", "notifications"],
        "limits" => %{"max_users" => 1000, "storage_gb" => 100}
      }
      PhoenixKit.Settings.update_json_setting("app_config", config)
  """
  use Ecto.Migration

  @doc """
  Run the V12 migration to add JSON support to settings.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add value_json column to existing phoenix_kit_settings table
    alter table(:phoenix_kit_settings, prefix: prefix) do
      # JSON/JSONB storage for complex configuration data
      # Using :map type which maps to JSONB in PostgreSQL
      # Null means this setting uses the traditional string value field
      add :value_json, :map, null: true
    end

    # Remove NOT NULL constraint from value column to support JSON-only settings
    execute """
    ALTER TABLE #{prefix_table_name("phoenix_kit_settings", prefix)}
    ALTER COLUMN value DROP NOT NULL
    """

    # Add comments to document the new capabilities
    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_settings", prefix)}.value_json IS
    'JSONB storage for complex settings data. When present, takes precedence over value field.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_settings", prefix)}.value IS
    'String value for simple settings. Can be NULL when using value_json for complex data.'
    """

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '12'"
  end

  @doc """
  Rollback the V12 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # First, clean up any NULL values in the value column by setting them to empty strings
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_settings", prefix)}
    SET value = ''
    WHERE value IS NULL AND value_json IS NOT NULL
    """

    # Restore NOT NULL constraint on value column
    execute """
    ALTER TABLE #{prefix_table_name("phoenix_kit_settings", prefix)}
    ALTER COLUMN value SET NOT NULL
    """

    # Remove value_json column from settings table
    alter table(:phoenix_kit_settings, prefix: prefix) do
      remove :value_json
    end

    # Restore original comment
    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_settings", prefix)}.value IS
    'String value for settings (required).'
    """

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '11'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
