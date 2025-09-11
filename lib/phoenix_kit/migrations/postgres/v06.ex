defmodule PhoenixKit.Migrations.Postgres.V06 do
  @moduledoc """
  PhoenixKit V06 Migration: Allow NULL Expiration Dates for Referral Codes

  This migration allows referral codes to have no expiration date by making 
  the expiration_date field nullable. This enables the creation of permanent 
  referral codes that never expire.

  ## Changes

  ### Referral Codes Enhancement
  - Modifies expiration_date column to allow NULL values
  - Enables creation of permanent referral codes
  - Maintains backward compatibility with existing dated codes
  - Supports "never expires" functionality

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Safe column modification with rollback support
  """
  use Ecto.Migration

  @doc """
  Run the V06 migration to allow NULL expiration dates.
  """
  def up(%{prefix: prefix} = _opts) do
    # Modify expiration_date column to allow NULL values
    alter table(:phoenix_kit_referral_codes, prefix: prefix) do
      modify :expiration_date, :utc_datetime_usec, null: true
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '6'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  def down(%{prefix: prefix} = _opts) do
    # Note: Rolling back this migration requires setting all NULL expiration_date
    # values to some default date before making the column NOT NULL again.
    # We'll set them to a far future date to maintain functionality.
    
    # Update any NULL expiration dates to a default future date
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_referral_codes", prefix)}
    SET expiration_date = '2099-12-31 23:59:59'::timestamp
    WHERE expiration_date IS NULL
    """

    # Modify expiration_date column back to NOT NULL
    alter table(:phoenix_kit_referral_codes, prefix: prefix) do
      modify :expiration_date, :utc_datetime_usec, null: false
    end

    # Set version comment back to V05
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '5'"
  end
end