defmodule PhoenixKit.Migrations.Postgres.V152 do
  @moduledoc """
  V152: Newsletters/CRM/Core restructuring — accumulator migration.

  Per the "one open migration" rule: while V152 is unreleased, every DDL
  step of the restructuring plan lands here as its own section rather than
  opening a new vNNN. Add new work as another `up_*`/`down_*` pair, called
  from `up/1`/`down/1` in application order (`down/1` unwinds in reverse).
  Keep each section's DDL self-contained and idempotent, same as any other
  migration in this chain.

  ## Section: send profiles move to core Email

  Creates `phoenix_kit_email_send_profiles` — the same shape V145 gave
  `phoenix_kit_newsletters_send_profiles`, now owned by core's
  `PhoenixKit.Email` namespace instead of the newsletters module (send
  profiles stop being newsletters-only, so any module can resolve one).
  Every row is copied across by its existing `uuid` (the PK on both
  tables, so nothing is renumbered) and the V145 table is then dropped.
  `idx_nl_send_profiles_integration`/`idx_nl_send_profiles_default` become
  `idx_email_send_profiles_integration`/`idx_email_send_profiles_default`.

  Does **not** touch `phoenix_kit_newsletters_broadcasts.send_profile_uuid`
  (added by V145) — it was already a bare UUID with no FK, so it still
  points at the same row regardless of which table now owns it.

  The copy+drop only runs when the V145 table is still present, so `up/1`
  is safe to re-run after it has already completed once (nothing left to
  copy, no "relation does not exist" on the second pass). Same for `down/1`
  against the V152 table.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @send_profile_columns """
  uuid, name, integration_uuid, provider_kind, from_name, from_email, reply_to,
  signature_html, signature_text, rate_per_hour, rate_per_day, pause_seconds,
  advanced, enabled, is_default, inserted_at, updated_at
  """

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    up_send_profiles_to_core_email(opts, prefix, p)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '152'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    down_send_profiles_to_core_email(opts, prefix, p)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '151'")
  end

  # ── Section: send profiles move to core Email ──

  defp up_send_profiles_to_core_email(opts, prefix, p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_email_send_profiles (
      uuid UUID PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
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
    CREATE INDEX IF NOT EXISTS idx_email_send_profiles_integration
    ON #{p}phoenix_kit_email_send_profiles(integration_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_email_send_profiles_default
    ON #{p}phoenix_kit_email_send_profiles(is_default) WHERE is_default = TRUE
    """)

    if table_exists?(opts, prefix, "phoenix_kit_newsletters_send_profiles") do
      execute("""
      INSERT INTO #{p}phoenix_kit_email_send_profiles (#{@send_profile_columns})
      SELECT #{@send_profile_columns} FROM #{p}phoenix_kit_newsletters_send_profiles
      ON CONFLICT (uuid) DO NOTHING
      """)

      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_send_profiles CASCADE")
    end
  end

  defp down_send_profiles_to_core_email(opts, prefix, p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_send_profiles (
      uuid UUID PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
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

    if table_exists?(opts, prefix, "phoenix_kit_email_send_profiles") do
      execute("""
      INSERT INTO #{p}phoenix_kit_newsletters_send_profiles (#{@send_profile_columns})
      SELECT #{@send_profile_columns} FROM #{p}phoenix_kit_email_send_profiles
      ON CONFLICT (uuid) DO NOTHING
      """)

      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_email_send_profiles CASCADE")
    end
  end

  # ── Shared helpers ──

  defp table_exists?(opts, prefix, table_name) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table_name}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
