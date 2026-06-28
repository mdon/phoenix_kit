defmodule PhoenixKit.Migrations.Postgres.V138 do
  @moduledoc """
  V138: CRM v1 — interaction tracker (contacts, companies, interactions).

  Five tables for the `phoenix_kit_crm` plugin's first real data model: a
  Contact (cloned in spirit from staff `Person`, but the user link is
  **optional**), a Company, the contact↔company membership (carrying free-form
  role + department on the edge), and the interaction log (entries + their
  resolvable "involved parties" with an as-of-then profile snapshot).

  ## phoenix_kit_crm_contacts
  A CRM contact (client/customer). Unlike staff `Person`, `user_uuid` is
  **nullable** — most contacts never log in. A partial unique index keeps it
  1:1 (one contact per user) only among the rows that *are* linked.

  ## phoenix_kit_crm_companies
  A company/organization record (its own data; not a login user).

  ## phoenix_kit_crm_company_memberships
  Contact↔company link, many-to-many, with free-form `role_in_company` and
  `department` on the edge + an `is_primary` flag (drives the headline display
  and the interaction snapshot).

  ## phoenix_kit_crm_interactions
  A logged interaction ("client called, discussed X"): type, when, body,
  the subject contact, and the staff user who logged it.

  ## phoenix_kit_crm_interaction_parties
  Flat, resolvable "who was involved" list per interaction. `raw_name` is
  always kept; `contact_uuid` / `staff_person_uuid` resolve to records when
  matched (exclusive-arc: at most one set). `party_snapshot` freezes the
  party's profile as it was at log time. `staff_person_uuid` is a **soft ref**
  (no FK) so the optional staff module stays optional.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # ── Contacts ──────────────────────────────────────────────────────
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_contacts (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255),
      status VARCHAR(50) NOT NULL DEFAULT 'active',
      email VARCHAR(255),
      phone VARCHAR(50),
      notes TEXT,
      user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    # One contact per linked user (only among rows that are actually linked).
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_contacts_user_uuid
    ON #{p}phoenix_kit_crm_contacts (user_uuid)
    WHERE user_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_contacts_status
    ON #{p}phoenix_kit_crm_contacts (status)
    """)

    # ── Companies ─────────────────────────────────────────────────────
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_companies (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255),
      status VARCHAR(50) NOT NULL DEFAULT 'active',
      website VARCHAR(255),
      email VARCHAR(255),
      phone VARCHAR(50),
      address TEXT,
      industry VARCHAR(255),
      notes TEXT,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_companies_status
    ON #{p}phoenix_kit_crm_companies (status)
    """)

    # ── Contact ↔ Company memberships ─────────────────────────────────
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_company_memberships (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
      company_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_companies(uuid) ON DELETE CASCADE,
      role_in_company VARCHAR(255),
      department VARCHAR(255),
      is_primary BOOLEAN NOT NULL DEFAULT false,
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_crm_company_memberships_uniq UNIQUE (contact_uuid, company_uuid)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_memberships_contact
    ON #{p}phoenix_kit_crm_company_memberships (contact_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_memberships_company
    ON #{p}phoenix_kit_crm_company_memberships (company_uuid)
    """)

    # ── Interactions ──────────────────────────────────────────────────
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_interactions (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
      interaction_type VARCHAR(50) NOT NULL DEFAULT 'note',
      occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      subject VARCHAR(255),
      body TEXT,
      owner_user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_interactions_contact
    ON #{p}phoenix_kit_crm_interactions (contact_uuid, occurred_at DESC)
    """)

    # ── Interaction parties (resolvable mentions) ─────────────────────
    # raw_name always kept; contact_uuid / staff_person_uuid resolve when
    # matched (at most one). staff_person_uuid is a SOFT ref (no FK) so the
    # optional staff module stays optional.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_interaction_parties (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      interaction_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_interactions(uuid) ON DELETE CASCADE,
      raw_name VARCHAR(255) NOT NULL,
      contact_uuid UUID REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE SET NULL,
      staff_person_uuid UUID,
      party_snapshot JSONB NOT NULL DEFAULT '{}',
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_crm_party_exclusive_arc
        CHECK (NOT (contact_uuid IS NOT NULL AND staff_person_uuid IS NOT NULL))
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_parties_interaction
    ON #{p}phoenix_kit_crm_interaction_parties (interaction_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_parties_contact
    ON #{p}phoenix_kit_crm_interaction_parties (contact_uuid)
    WHERE contact_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_parties_staff_person
    ON #{p}phoenix_kit_crm_interaction_parties (staff_person_uuid)
    WHERE staff_person_uuid IS NOT NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '138'")
  end

  @doc """
  Rolls V138 back by dropping the five CRM v1 tables in reverse dependency
  order.

  **Lossy rollback:** all contacts, companies, memberships, interactions, and
  party rows are lost. Back up before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_interaction_parties CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_interactions CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_company_memberships CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_companies CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_contacts CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '137'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
