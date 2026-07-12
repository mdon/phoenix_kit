defmodule PhoenixKit.Migrations.Postgres.V143 do
  @moduledoc """
  V143: Newsletters Send Settings — `phoenix_kit_newsletters_send_profiles`.

  Adds the send-profile table backing the newsletters module's "Send
  Settings" admin screen: named send configurations that reference a
  core Integrations connection (by `integration_uuid`, no FK — consistent
  with the codebase's loose-UUID pattern for cross-module references, see
  v138/v140) and carry per-account send parameters (from-name/email,
  reply-to, signature, rate limits, `advanced` per-provider extras).
  Multiple profiles may share one integration. At most one profile may be
  `is_default` (the service-wide default), enforced by a partial unique
  index.

  Also adds `send_profile_uuid` (bare UUID, no FK) to
  `phoenix_kit_newsletters_broadcasts`, letting each broadcast pin which
  send profile delivers it — folded in here rather than a follow-up
  migration since V143 hasn't shipped anywhere yet.

  All statements are idempotent, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_send_profiles (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      integration_uuid UUID NOT NULL,
      provider_kind VARCHAR(40) NOT NULL,
      from_name VARCHAR(255), from_email VARCHAR(255), reply_to VARCHAR(255),
      signature_html TEXT, signature_text TEXT,
      rate_per_hour INTEGER, rate_per_day INTEGER, pause_seconds INTEGER DEFAULT 0,
      advanced JSONB NOT NULL DEFAULT '{}'::jsonb,
      enabled BOOLEAN NOT NULL DEFAULT TRUE,
      is_default BOOLEAN NOT NULL DEFAULT FALSE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_nl_send_profiles_integration
    ON #{p}phoenix_kit_newsletters_send_profiles(integration_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_nl_send_profiles_default
    ON #{p}phoenix_kit_newsletters_send_profiles(is_default) WHERE is_default = TRUE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
    ADD COLUMN IF NOT EXISTS send_profile_uuid UUID
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")
  end

  def down(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
    DROP COLUMN IF EXISTS send_profile_uuid
    """)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_send_profiles CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '142'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
