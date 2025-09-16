defmodule PhoenixKit.Migrations.Postgres.V09 do
  @moduledoc """
  PhoenixKit V09 Migration: Email Blocklist Support

  This migration adds the email blocklist functionality to the email tracking system,
  allowing management of blocked email addresses for rate limiting and spam prevention.

  ## Changes

  ### Email Blocklist System
  - Adds phoenix_kit_email_blocklist table for blocked email addresses
  - Creates indexes for efficient blocklist queries
  - Supports temporary and permanent blocks with expiration
  - Provides audit trail for block management

  ### New Features
  - **Blocklist Management**: Store blocked email addresses with reasons
  - **Expiration Support**: Temporary blocks with automatic expiration
  - **User Tracking**: Track which user added the block
  - **Audit Trail**: Complete history of block additions and removals
  - **Performance Optimized**: Efficient indexes for fast lookups

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for email lookup and expiration queries
  - Unique constraint to prevent duplicate blocks
  """
  use Ecto.Migration

  @doc """
  Run the V09 migration to add email blocklist support.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add email blocklist table
    create_if_not_exists table(:phoenix_kit_email_blocklist, prefix: prefix) do
      # Email address to block (normalized to lowercase)
      add :email, :string, null: false

      # Reason for blocking (e.g., "manual_block", "bounce_limit", "spam_pattern")
      add :reason, :string, null: false

      # Optional expiration date (null for permanent blocks)
      add :expires_at, :utc_datetime_usec, null: true

      # User ID who added the block (optional for automated blocks)
      add :user_id, :integer, null: true

      # Timestamps
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Create indexes for efficient queries

    # Primary lookup index for email addresses
    create_if_not_exists unique_index(:phoenix_kit_email_blocklist, [:email],
                           prefix: prefix,
                           name: :phoenix_kit_email_blocklist_email_uidx
                         )

    # Index for expired blocks cleanup
    create_if_not_exists index(:phoenix_kit_email_blocklist, [:expires_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_blocklist_expires_at_idx
                         )

    # Index for audit trail queries
    create_if_not_exists index(:phoenix_kit_email_blocklist, [:user_id, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_blocklist_user_inserted_idx
                         )

    # Index for reason-based queries
    create_if_not_exists index(:phoenix_kit_email_blocklist, [:reason, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_blocklist_reason_inserted_idx
                         )

    # Composite index for email and expiration queries
    create_if_not_exists index(:phoenix_kit_email_blocklist, [:email, :expires_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_blocklist_email_expires_idx
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '9'"
  end

  @doc """
  Rollback the V09 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(:phoenix_kit_email_blocklist, [:email, :expires_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_blocklist_email_expires_idx
                   )

    drop_if_exists index(:phoenix_kit_email_blocklist, [:reason, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_blocklist_reason_inserted_idx
                   )

    drop_if_exists index(:phoenix_kit_email_blocklist, [:user_id, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_blocklist_user_inserted_idx
                   )

    drop_if_exists index(:phoenix_kit_email_blocklist, [:expires_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_blocklist_expires_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_blocklist, [:email],
                     prefix: prefix,
                     name: :phoenix_kit_email_blocklist_email_uidx
                   )

    # Drop table
    drop_if_exists table(:phoenix_kit_email_blocklist, prefix: prefix)

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '8'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
