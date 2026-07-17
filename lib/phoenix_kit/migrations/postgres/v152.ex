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

  ## Section: CRM contact lists

  Two new tables plus three columns on the existing V138
  `phoenix_kit_crm_contacts`, for Stage 3 of the restructuring plan
  (list-based sending + account import):

    * `phoenix_kit_crm_lists` — a named, sluggable list (`status`
      active/archived, `subscribable` pre-provisioned for the Stage-4
      preference center, `subscriber_count` a maintained cache).
    * `phoenix_kit_crm_list_members` — the list↔contact join, carrying a
      denormalized `email` snapshot taken at add-time (so a list survives
      a later change to the contact's own email) and its own `status`
      (subscribed/pending/removed) and `source` (manual/import/form/api).
      `UNIQUE (list_uuid, contact_uuid)` keeps one membership row per
      contact per list; `UNIQUE (list_uuid, email) WHERE email IS NOT
      NULL` (`idx_crm_list_members_list_email`) is the actual per-list
      email uniqueness guard — a `removed` member still holds its email
      slot, so re-importing the same address cannot silently create a
      second, resubscribed row under it.
    * `phoenix_kit_crm_contacts.locale` / `.opted_out_at` / `.consent` —
      opt-out and consent live on the contact (not the membership), so
      an opt-out applies across every list the contact belongs to; the
      Stage-4 send path checks membership `subscribed` AND contact not
      opted out.

  citext (already ensured by V151) backs `email` here too, for the same
  case-insensitive matching. All operations are idempotent.
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
    up_crm_contact_lists(opts, prefix, p)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '152'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Reverse of up/1: CRM contact lists was added second, so it unwinds first.
    down_crm_contact_lists(opts, prefix, p)
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

  # ── Section: CRM contact lists ──

  defp up_crm_contact_lists(_opts, prefix, p) do
    Helpers.ensure_extension!("citext")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_lists (
      uuid UUID PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'archived')),
      subscribable BOOLEAN NOT NULL DEFAULT FALSE,
      subscriber_count INTEGER NOT NULL DEFAULT 0,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_lists_slug
    ON #{p}phoenix_kit_crm_lists (slug)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_list_members (
      uuid UUID PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
      list_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_lists(uuid) ON DELETE CASCADE,
      contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
      email CITEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'subscribed'
        CHECK (status IN ('subscribed', 'pending', 'removed')),
      subscribed_at TIMESTAMPTZ,
      unsubscribed_at TIMESTAMPTZ,
      source VARCHAR(20) NOT NULL DEFAULT 'manual'
        CHECK (source IN ('manual', 'import', 'form', 'api')),
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_list_members_list_contact
    ON #{p}phoenix_kit_crm_list_members (list_uuid, contact_uuid)
    """)

    # Per-list email uniqueness on the denormalized snapshot — a `removed`
    # member still holds its email slot, so re-importing the same address
    # cannot silently resubscribe it under a second row.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_list_members_list_email
    ON #{p}phoenix_kit_crm_list_members (list_uuid, email)
    WHERE email IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_list_members_contact
    ON #{p}phoenix_kit_crm_list_members (contact_uuid)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_crm_contacts
    ADD COLUMN IF NOT EXISTS locale VARCHAR(10)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_crm_contacts
    ADD COLUMN IF NOT EXISTS opted_out_at TIMESTAMPTZ
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_crm_contacts
    ADD COLUMN IF NOT EXISTS consent JSONB NOT NULL DEFAULT '{}'
    """)
  end

  defp down_crm_contact_lists(_opts, _prefix, p) do
    execute("ALTER TABLE #{p}phoenix_kit_crm_contacts DROP COLUMN IF EXISTS consent")
    execute("ALTER TABLE #{p}phoenix_kit_crm_contacts DROP COLUMN IF EXISTS opted_out_at")
    execute("ALTER TABLE #{p}phoenix_kit_crm_contacts DROP COLUMN IF EXISTS locale")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_list_members CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_lists CASCADE")
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
