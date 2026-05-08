defmodule PhoenixKit.Migrations.Postgres.V109 do
  @moduledoc """
  V109: Rename Customer Service module settings keys and permission module_key to customer_support.

  The `customer_service` module has been renamed to `customer_support`. This migration
  renames all associated settings keys and role permission module_key values
  to match the new module identity.

  ## Changes

  - Rename 7 settings keys from `customer_service_*` → `customer_support_*`
  - Rename auto-granted permission key from `auto_granted_perm:customer_service` → `auto_granted_perm:customer_support`
  - Rename role permission module_key from `customer_service` → `customer_support`

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    table = "#{prefix_str(prefix)}phoenix_kit_settings"
    perms_table = "#{prefix_str(prefix)}phoenix_kit_role_permissions"

    rename_setting(table, "customer_service_enabled", "customer_support_enabled")
    rename_setting(table, "customer_service_per_page", "customer_support_per_page")

    rename_setting(
      table,
      "customer_service_comments_enabled",
      "customer_support_comments_enabled"
    )

    rename_setting(
      table,
      "customer_service_internal_notes_enabled",
      "customer_support_internal_notes_enabled"
    )

    rename_setting(
      table,
      "customer_service_attachments_enabled",
      "customer_support_attachments_enabled"
    )

    rename_setting(table, "customer_service_allow_reopen", "customer_support_allow_reopen")

    rename_setting(
      table,
      "auto_granted_perm:customer_service",
      "auto_granted_perm:customer_support"
    )

    rename_role_permission(perms_table, "customer_service", "customer_support")

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '109'")
  end

  # Renames a settings key. If the target already exists, deletes the source to avoid
  # unique constraint violations (handles the case where new keys were pre-seeded).
  defp rename_setting(table, from_key, to_key) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{table} WHERE key = '#{to_key}') THEN
        DELETE FROM #{table} WHERE key = '#{from_key}';
      ELSE
        UPDATE #{table} SET key = '#{to_key}' WHERE key = '#{from_key}';
      END IF;
    END $$;
    """)
  end

  # Renames role permission module_key. If target already exists for the same role,
  # deletes the source row to avoid unique constraint violations.
  defp rename_role_permission(table, from_key, to_key) do
    execute("""
    DO $$
    BEGIN
      -- Delete source rows where target already exists for the same role
      DELETE FROM #{table} src
      WHERE src.module_key = '#{from_key}'
        AND EXISTS (
          SELECT 1 FROM #{table} tgt
          WHERE tgt.module_key = '#{to_key}' AND tgt.role_uuid = src.role_uuid
        );

      -- Rename remaining rows
      UPDATE #{table} SET module_key = '#{to_key}' WHERE module_key = '#{from_key}';
    END $$;
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    table = "#{prefix_str(prefix)}phoenix_kit_settings"
    perms_table = "#{prefix_str(prefix)}phoenix_kit_role_permissions"

    rename_role_permission(perms_table, "customer_support", "customer_service")

    rename_setting(
      table,
      "auto_granted_perm:customer_support",
      "auto_granted_perm:customer_service"
    )

    rename_setting(table, "customer_support_allow_reopen", "customer_service_allow_reopen")

    rename_setting(
      table,
      "customer_support_attachments_enabled",
      "customer_service_attachments_enabled"
    )

    rename_setting(
      table,
      "customer_support_internal_notes_enabled",
      "customer_service_internal_notes_enabled"
    )

    rename_setting(
      table,
      "customer_support_comments_enabled",
      "customer_service_comments_enabled"
    )

    rename_setting(table, "customer_support_per_page", "customer_service_per_page")
    rename_setting(table, "customer_support_enabled", "customer_service_enabled")

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '108'")
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
