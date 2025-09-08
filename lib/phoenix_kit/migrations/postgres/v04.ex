defmodule PhoenixKit.Migrations.Postgres.V04 do
  @moduledoc """
  PhoenixKit V04 Migration: Settings Module Column + Referral System

  This migration adds modular settings support and implements the referral system
  for enhanced user management and feature organization.

  ## Changes

  ### Settings Table Enhancement
  - Adds module column to phoenix_kit_settings table for feature-specific settings
  - Updates existing settings with appropriate module associations
  - Maintains backward compatibility with existing settings

  ### Referral System
  - Adds phoenix_kit_referral_codes table for managing referral codes
  - Adds phoenix_kit_referral_code_usage table for tracking code usage
  - Supports referral code creation, validation, and usage tracking
  - Integrates with settings system for referral-specific configuration

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Proper foreign key relationships and constraints
  - Optimized indexes for performance
  """
  use Ecto.Migration

  @doc """
  Run the V04 migration to add module column and referral system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add module column to existing settings table
    alter table(:phoenix_kit_settings, prefix: prefix) do
      add :module, :string, null: true
    end

    # Create referral codes table
    create_if_not_exists table(:phoenix_kit_referral_codes, prefix: prefix) do
      add :code, :string, null: false
      add :description, :string, null: false
      add :status, :boolean, null: false, default: true
      add :number_of_uses, :integer, null: false, default: 0
      add :max_uses, :integer, null: false
      add :created_by, :integer, null: false
      add :date_created, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :expiration_date, :utc_datetime_usec, null: false
    end

    # Create referral code usage tracking table
    create_if_not_exists table(:phoenix_kit_referral_code_usage, prefix: prefix) do
      add :code_id, :integer, null: false
      add :used_by, :integer, null: false
      add :date_used, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Add unique constraint on referral code string
    create_if_not_exists unique_index(:phoenix_kit_referral_codes, [:code], prefix: prefix, name: :phoenix_kit_referral_codes_code_uidx)

    # Add foreign key constraint for referral code usage
    create_if_not_exists index(:phoenix_kit_referral_code_usage, [:code_id], prefix: prefix, name: :phoenix_kit_referral_code_usage_code_id_idx)
    create_if_not_exists index(:phoenix_kit_referral_code_usage, [:used_by], prefix: prefix, name: :phoenix_kit_referral_code_usage_used_by_idx)
    create_if_not_exists index(:phoenix_kit_referral_code_usage, [:date_used], prefix: prefix, name: :phoenix_kit_referral_code_usage_date_used_idx)

    # Add foreign key constraint for referral code usage to referral codes
    alter table(:phoenix_kit_referral_code_usage, prefix: prefix) do
      modify :code_id, references(:phoenix_kit_referral_codes, on_delete: :delete_all, prefix: prefix)
    end

    # Update existing settings to assign them to core system module
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_settings", prefix)}
    SET module = 'system'
    WHERE key IN ('time_zone', 'date_format', 'time_format', 'project_title')
    """

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '4'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  def down(%{prefix: prefix} = _opts) do
    # Drop indexes and constraints first
    drop_if_exists index(:phoenix_kit_referral_code_usage, [:date_used], prefix: prefix, name: :phoenix_kit_referral_code_usage_date_used_idx)
    drop_if_exists index(:phoenix_kit_referral_code_usage, [:used_by], prefix: prefix, name: :phoenix_kit_referral_code_usage_used_by_idx)
    drop_if_exists index(:phoenix_kit_referral_code_usage, [:code_id], prefix: prefix, name: :phoenix_kit_referral_code_usage_code_id_idx)
    drop_if_exists index(:phoenix_kit_referral_codes, [:code], prefix: prefix, name: :phoenix_kit_referral_codes_code_uidx)

    # Drop referral system tables
    drop_if_exists table(:phoenix_kit_referral_code_usage, prefix: prefix)
    drop_if_exists table(:phoenix_kit_referral_codes, prefix: prefix)

    # Remove module column from settings table
    alter table(:phoenix_kit_settings, prefix: prefix) do
      remove :module
    end

    # Set version comment back to V03
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '3'"
  end
end
