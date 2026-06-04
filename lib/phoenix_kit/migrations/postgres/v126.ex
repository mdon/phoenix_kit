defmodule PhoenixKit.Migrations.Postgres.V126 do
  @moduledoc """
  V126: Allow standalone notifications.

  Until now every `phoenix_kit_notifications` row had to point at an
  `activity_uuid` (NOT NULL) — a notification was strictly a per-user
  projection of an activity. This relaxes that so a notification can
  exist on its own:

    1. Drops NOT NULL on `activity_uuid`. The unique
       `(activity_uuid, recipient_uuid)` index keeps working — Postgres
       treats NULLs as distinct by default, so a recipient can hold many
       standalone notifications.
    2. Adds `metadata JSONB NOT NULL DEFAULT '{}'` so a standalone
       notification carries its own display content. `Render` reads the
       same `notification_text` / `notification_icon` / `notification_link`
       keys it already honors on activity metadata.

  Idempotent: `DROP NOT NULL` is a no-op when already nullable and the
  column add is `IF NOT EXISTS`.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_notifications ALTER COLUMN activity_uuid DROP NOT NULL")

    execute(
      "ALTER TABLE #{p}phoenix_kit_notifications ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '126'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_notifications DROP COLUMN IF EXISTS metadata")

    # Reverting the feature means activity-less notifications can no longer
    # exist — drop them before restoring NOT NULL so the constraint holds.
    execute("DELETE FROM #{p}phoenix_kit_notifications WHERE activity_uuid IS NULL")

    execute("ALTER TABLE #{p}phoenix_kit_notifications ALTER COLUMN activity_uuid SET NOT NULL")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '125'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
