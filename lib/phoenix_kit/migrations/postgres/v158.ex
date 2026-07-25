defmodule PhoenixKit.Migrations.Postgres.V158 do
  @moduledoc """
  V158: broadcast attachments (accumulator).

  Opened as the accumulator for the newsletters restructuring work, with
  one section. Shipped in 1.7.211 before a second section landed, so per
  the one-open-migration rule it is now closed — the next restructuring
  section opens V159 rather than appending here.

  ## Section: `phoenix_kit_newsletters_broadcasts.attachments`

  A JSONB array of Storage file uuids (`phoenix_kit_files.uuid`) to be
  attached to every email of the broadcast. Deliberately a bare uuid
  list, not an FK'd join table:

  - The soft-reference pattern matches this table's existing
    `crm_list_uuid`/`source_params` precedent — newsletters rows never
    hold FKs into other modules' tables, so a file deleted from Media
    later degrades to "skipped at send time" (the worker resolves each
    uuid via Storage and skips misses) rather than blocking the delete
    with a RESTRICT nobody can see the reason for.
  - Order matters to the sender (attachments appear in the email in list
    order), which a join table would need an extra column to preserve;
    a JSONB array carries it for free.

  The application-side writer (broadcast editor + `Broadcast` changeset,
  newsletters package) validates entries are uuids and caps the count;
  the column itself only guarantees "a JSON array" via the CHECK — the
  DB-level backstop that a stray writer can't store an object/scalar
  here and crash every reader.

  ## down/1

  Drops the CHECK, then the column. Lossy in the ordinary sense — a
  broadcast's attachment selection is destroyed, not merely orphaned —
  but it's an editor selection rather than delivery-identifying history,
  so it carries none of the "outlives the column" risk V155's
  `crm_contact_uuid` does. The coordination rule from V155 still holds
  though: the writer lives in `phoenix_kit_newsletters`, a separate
  package with its own release cycle, so rolling V158 back while a
  newsletters release that reads/writes `attachments` is still deployed
  breaks that release outright. Roll both back together.

  All operations idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
      ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'::jsonb
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP CONSTRAINT IF EXISTS phoenix_kit_newsletters_broadcasts_attachments_is_array"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_attachments_is_array
      CHECK (jsonb_typeof(attachments) = 'array')
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '158'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP CONSTRAINT IF EXISTS phoenix_kit_newsletters_broadcasts_attachments_is_array"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP COLUMN IF EXISTS attachments"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '157'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
