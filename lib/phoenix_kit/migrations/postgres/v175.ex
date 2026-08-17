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

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '175'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

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
