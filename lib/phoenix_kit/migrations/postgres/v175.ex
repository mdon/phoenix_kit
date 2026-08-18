defmodule PhoenixKit.Migrations.Postgres.V175 do
  @moduledoc """
  V175: `phoenix_kit_buckets.integration_uuid` — an alternative credential
  source for cloud storage buckets.

  `phoenix_kit_buckets` stores `access_key_id`/`secret_access_key` for S3,
  B2, R2 and Tigris buckets directly on the row. A `PhoenixKit.Integrations`
  connection (an in-flight, separately-shipped `object_storage` provider
  type) can hold the same credentials instead, letting a bucket point at
  it by uuid rather than duplicating the keys.

  No FK — projects/mentions/comments (V165/V166) and the email/newsletters
  send profiles (V145/V152) already reference `Integrations` rows the same
  loose way, since `phoenix_kit_settings` is where those rows actually
  live and a cross-module FK is not this codebase's pattern for it.
  `Bucket.changeset/2` rejects setting `integration_uuid` alongside
  `access_key_id`/`secret_access_key` in the same change — exactly one
  credential source, never two, so there is never a question of which one
  is authoritative.

  Partial index (`WHERE integration_uuid IS NOT NULL`) mirrors V166's
  `attributed_project_uuid` index — most buckets are `local` and carry
  neither column.

  ## secret_access_key: varchar(255) -> text

  Same changeset now encrypts `secret_access_key` (`enc:v1:` + base64 of
  iv+tag+ciphertext) before it lands in this column. That encoding runs
  roughly 1.6x the plaintext length, so a plaintext secret over ~158 chars
  overflowed the original `varchar(255)` with a raw Postgres 22001 error
  the changeset never validated against. Widening to `text` removes the
  ceiling instead of guessing a new arbitrary one — Postgres stores
  `text`/`varchar` identically on disk, so this is a metadata-only change,
  folded into this not-yet-shipped migration rather than a separate V176.
  `down/1` deliberately does NOT narrow it back to `varchar(255)`: a value
  written after the widening could already exceed that, and shrinking a
  column is exactly the kind of "down" that trades a clean rollback for a
  silent truncation/error on data this migration never touched.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_buckets
      ADD COLUMN IF NOT EXISTS integration_uuid UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_buckets_integration_uuid_idx
      ON #{p}phoenix_kit_buckets (integration_uuid)
      WHERE integration_uuid IS NOT NULL
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_buckets
      ALTER COLUMN secret_access_key TYPE TEXT
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '175'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # secret_access_key stays `text` — see moduledoc.

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_buckets_integration_uuid_idx")

    execute("""
    ALTER TABLE #{p}phoenix_kit_buckets
      DROP COLUMN IF EXISTS integration_uuid
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '174'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
