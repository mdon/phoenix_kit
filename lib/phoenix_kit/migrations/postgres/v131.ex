defmodule PhoenixKit.Migrations.Postgres.V131 do
  @moduledoc """
  V131: `metadata JSONB` on `phoenix_kit_staff_people`.

  Adds a general-purpose `metadata JSONB NOT NULL DEFAULT '{}'` column to
  the staff people table, mirroring the shape `phoenix_kit_entities`
  `entity_data` already uses. The immediate consumer is soft-delete:
  `PhoenixKitStaff.Staff.trash_person/2` stashes the row's prior
  lifecycle status under `metadata["trashed_from_status"]` so
  `restore_person/2` can return the person to active/inactive instead of
  unconditionally landing on "active".

  The column is deliberately generic (not a `trashed_from_status`-specific
  field) so future per-person metadata can reuse it without another
  migration — same rationale as the entity_data metadata column.

  Idempotent: `ADD COLUMN IF NOT EXISTS`, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_staff_people ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '131'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS metadata")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '130'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
