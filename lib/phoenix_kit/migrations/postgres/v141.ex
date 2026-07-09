defmodule PhoenixKit.Migrations.Postgres.V141 do
  @moduledoc """
  V141: Personal calendar events + participants for the
  `phoenix_kit_calendar` module.

  One implicit personal calendar per user — events are keyed by
  `owner_uuid` (no calendars table in v1; recurrence is deliberately
  deferred).

  Time model (mirrors `phoenix_live_calendar`'s Event semantics):

  - Timed events use the `starts_at`/`ends_at` UTC pair; `ends_at` is
    EXCLUSIVE (`[start, end)`, iCal/RFC 5545 style).
  - All-day events use the `starts_on`/`ends_on` DATE pair (also
    end-exclusive) — proper date semantics instead of UTC-midnight
    instants, so a "day" never shifts across timezones/DST.
  - A CHECK constraint enforces exactly one pair per row, matching the
    `all_day` flag, with end > start on both pairs.

  `owner_uuid` cascades on user delete — a personal calendar follows its
  account's lifecycle. `location_uuid` optionally links a stored location
  from the locations module (loose uuid reference, NO cross-module FK —
  the location NAME is snapshotted into the `location` string at save, so
  rendering never needs the locations module).

  ## Participants

  `phoenix_kit_calendar_event_participants` attaches people to an event.
  Loose `kind` + `target_uuid` references (activity-feed pattern — no
  cross-module FKs) with a `display_name` snapshot frozen at save, so
  participants render even if a source module is later disabled or the
  record deleted. Kinds: `user`, `staff_person`, `crm_contact`,
  `crm_company`, `free_text` (free text has no target and grants no
  visibility).

  Visibility is resolved LIVE at query time by joining the PHYSICAL
  staff/CRM tables (they exist in every install via these core
  migrations, so no module code is required and empty tables no-op):
  a company participant means "whoever is a member of that company NOW",
  and a staff person / CRM contact resolves through its current
  `user_uuid` link. `added_by_uuid` records who attached the participant.

  All statements are idempotent AND additive — this migration was
  extended in place while unreleased (per project policy); re-running it
  on a database that has the earlier shape adds only the missing pieces.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_calendar_events (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      owner_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      title VARCHAR(255) NOT NULL,
      description TEXT,
      location VARCHAR(255),
      all_day BOOLEAN NOT NULL DEFAULT FALSE,
      starts_at TIMESTAMP(0),
      ends_at TIMESTAMP(0),
      starts_on DATE,
      ends_on DATE,
      color VARCHAR(50),
      status VARCHAR(20) NOT NULL DEFAULT 'confirmed',
      inserted_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      CONSTRAINT calendar_event_time_shape CHECK (
        (
          all_day = FALSE
          AND starts_at IS NOT NULL AND ends_at IS NOT NULL
          AND starts_on IS NULL AND ends_on IS NULL
          AND ends_at > starts_at
        )
        OR
        (
          all_day = TRUE
          AND starts_on IS NOT NULL AND ends_on IS NOT NULL
          AND starts_at IS NULL AND ends_at IS NULL
          AND ends_on > starts_on
        )
      ),
      CONSTRAINT calendar_event_status CHECK (status IN ('confirmed', 'cancelled'))
    )
    """)

    # Loose link to a stored location (locations module); the name is
    # snapshotted into `location`, so this is enrichment only.
    execute("""
    ALTER TABLE #{p}phoenix_kit_calendar_events
    ADD COLUMN IF NOT EXISTS location_uuid UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_at
    ON #{p}phoenix_kit_calendar_events (owner_uuid, starts_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_on
    ON #{p}phoenix_kit_calendar_events (owner_uuid, starts_on)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_calendar_event_participants (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      event_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_calendar_events(uuid) ON DELETE CASCADE,
      kind VARCHAR(20) NOT NULL,
      target_uuid UUID,
      display_name VARCHAR(255) NOT NULL,
      added_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      CONSTRAINT calendar_participant_kind CHECK (
        kind IN ('user', 'staff_person', 'crm_contact', 'crm_company', 'free_text')
      ),
      CONSTRAINT calendar_participant_shape CHECK (
        (kind = 'free_text' AND target_uuid IS NULL)
        OR (kind <> 'free_text' AND target_uuid IS NOT NULL)
      )
    )
    """)

    # One row per (event, kind, target); free-text dedups case-insensitively
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_participants_target
    ON #{p}phoenix_kit_calendar_event_participants (event_uuid, kind, target_uuid)
    WHERE target_uuid IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_participants_free_text
    ON #{p}phoenix_kit_calendar_event_participants (event_uuid, LOWER(display_name))
    WHERE kind = 'free_text'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_participants_event
    ON #{p}phoenix_kit_calendar_event_participants (event_uuid)
    """)

    # Reverse direction: "which events does this person participate in" —
    # drives the live visibility resolution on personal calendars
    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_participants_kind_target
    ON #{p}phoenix_kit_calendar_event_participants (kind, target_uuid)
    WHERE target_uuid IS NOT NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '141'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_calendar_event_participants")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_calendar_events")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '140'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
