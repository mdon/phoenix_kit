defmodule PhoenixKit.Migrations.Postgres.V05 do
  @moduledoc """
  PhoenixKit V05 Migration: Add Beneficiary Field to Referral Codes

  This migration adds a beneficiary field to the existing referral codes table
  to track which user should receive benefits when their referral code is used.

  ## Changes

  ### Referral Codes Enhancement
  - Adds beneficiary integer field to phoenix_kit_referral_codes table
  - Allows tracking which user benefits from referral code usage
  - Supports reward/benefit systems for referral programs
  - Maintains backward compatibility with existing referral codes

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Proper field addition with rollback support
  """
  use Ecto.Migration

  @doc """
  Run the V05 migration to add beneficiary field to referral codes table.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add beneficiary column to existing referral_codes table
    alter table(:phoenix_kit_referral_codes, prefix: prefix) do
      add :beneficiary, :integer, null: true
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '5'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  def down(%{prefix: prefix} = _opts) do
    # Remove beneficiary column from referral_codes table
    alter table(:phoenix_kit_referral_codes, prefix: prefix) do
      remove :beneficiary
    end

    # Set version comment back to V04
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '4'"
  end
end
