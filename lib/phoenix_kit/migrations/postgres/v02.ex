defmodule PhoenixKit.Migrations.Postgres.V02 do
  @moduledoc """
  PhoenixKit Migration V02: Remove is_active column from role assignments.

  This migration removes the is_active column from role assignments table,
  simplifying the role system to use direct deletion instead of soft deletion.

  ## Changes

  - Remove is_active column from phoenix_kit_user_role_assignments table
  - Remove performance indexes that used is_active column
  - Clean up existing inactive role assignments (convert to actual deletions)

  ## Migration Strategy

  1. Remove inactive assignments (where is_active = false)
  2. Drop indexes that reference is_active column
  3. Drop is_active column from role assignments table

  ## Rollback Strategy

  - Adds back is_active column with default true
  - Recreates performance indexes
  - All existing assignments become active by default

  **Note**: This migration cannot preserve inactive assignment history.
  Consider backing up inactive assignments if audit trail is required.
  """

  use Ecto.Migration

  @doc """
  Run the V02 migration to remove is_active column.
  """
  def up(%{prefix: prefix} = _opts) do
    # Step 1: Clean up inactive role assignments
    # This permanently removes assignments that were marked as inactive
    execute("""
    DELETE FROM #{prefix_table("phoenix_kit_user_role_assignments", prefix)}
    WHERE is_active = false
    """)

    # Step 2: Drop performance indexes that reference is_active
    drop_if_exists index(:phoenix_kit_user_role_assignments, [:user_id, :is_active],
                     prefix: prefix,
                     name: :idx_user_role_assignments_user_active
                   )

    drop_if_exists index(:phoenix_kit_user_role_assignments, [:role_id, :is_active],
                     prefix: prefix,
                     name: :idx_user_role_assignments_role_active
                   )

    # Step 3: Remove is_active column from role assignments table
    alter table(:phoenix_kit_user_role_assignments, prefix: prefix) do
      remove :is_active
    end

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '2'"
  end

  @doc """
  Rollback V02 migration by restoring is_active column.

  **Warning**: This cannot restore previously deleted inactive assignments.
  """
  def down(%{prefix: prefix} = _opts) do
    # Step 1: Add back is_active column (all existing assignments become active)
    alter table(:phoenix_kit_user_role_assignments, prefix: prefix) do
      add :is_active, :boolean, default: true, null: false
    end

    # Step 2: Update all existing assignments to be active
    execute("""
    UPDATE #{prefix_table("phoenix_kit_user_role_assignments", prefix)}
    SET is_active = true
    """)

    # Step 3: Recreate performance indexes
    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:user_id, :is_active],
                           prefix: prefix,
                           name: :idx_user_role_assignments_user_active
                         )

    create_if_not_exists index(:phoenix_kit_user_role_assignments, [:role_id, :is_active],
                           prefix: prefix,
                           name: :idx_user_role_assignments_role_active
                         )

    # Update version comment back to V01
    execute "COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '1'"
  end

  # Helper function to build table name with optional prefix
  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, prefix) when is_binary(prefix), do: "#{prefix}.#{table_name}"

  @doc """
  Returns the migration version.
  """
  def version, do: 2

  @doc """
  Returns migration description for logging and status display.
  """
  def description do
    "Remove is_active column from role assignments - simplify role system to use direct deletion"
  end

  @doc """
  Returns whether this migration is destructive (cannot be safely rolled back).
  """
  def destructive?, do: true

  @doc """
  Returns estimated migration time for progress tracking.
  """
  def estimated_time, do: "< 1 minute"

  @doc """
  Validates prerequisites before running migration.

  Ensures V01 migration has been applied.
  """
  def validate_prerequisites(repo, prefix \\ nil) do
    # Check if phoenix_kit_user_role_assignments table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit_user_role_assignments'
      #{if prefix, do: "AND table_schema = '#{prefix}'", else: ""}
    )
    """

    case repo.query(table_exists_query, []) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, "V01 migration must be applied first"}
      {:error, reason} -> {:error, "Failed to check prerequisites: #{inspect(reason)}"}
    end
  end

  @doc """
  Pre-migration checks and warnings.

  Counts inactive assignments that will be permanently deleted.
  """
  def pre_migration_report(repo, prefix \\ nil) do
    inactive_count_query = """
    SELECT COUNT(*) FROM #{prefix_table("phoenix_kit_user_role_assignments", prefix)}
    WHERE is_active = false
    """

    case repo.query(inactive_count_query, []) do
      {:ok, %{rows: [[count]]}} when count > 0 ->
        {:warning, "#{count} inactive role assignments will be permanently deleted"}

      {:ok, %{rows: [[0]]}} ->
        {:ok, "No inactive assignments to clean up"}

      {:error, reason} ->
        {:error, "Failed to generate pre-migration report: #{inspect(reason)}"}
    end
  end
end
