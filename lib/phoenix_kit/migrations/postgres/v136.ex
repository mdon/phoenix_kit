defmodule PhoenixKit.Migrations.Postgres.V136 do
  @moduledoc """
  V136: Employment history for `phoenix_kit_staff`.

  Replaces the single flat employment span on `phoenix_kit_staff_people`
  (`employment_type` / `employment_start_date` / `employment_end_date` /
  `job_title` / `work_location`) with a first-class **history** of employment
  spans, surfaced as a dedicated tab on the person profile.

  Creates `phoenix_kit_staff_employments` — one row per span, carrying the
  employment type, a translatable `job_title`, the org placement at the time
  (`primary_department_uuid` + a `primary_team_uuid` snapshot), the date range
  (`employment_end_date IS NULL` = the current/open span), `work_location`, and
  free-text `notes`.

  ## Single open span per person

  A partial unique index enforces **at most one open span** (`employment_end_date
  IS NULL`) per person — the "current" employment. The app context closes the
  prior open span when a new one starts.

  ## Denormalized "current" mirror

  The matching columns already on `phoenix_kit_staff_people` are kept as a
  denormalized mirror of the current (open) span — the app's `sync_current/1`
  writes them in the same transaction as any span change, so existing readers
  (overview org tree, people list) need no join. This migration does NOT drop
  those columns.

  ## Backfill

  One open span per existing person is seeded from their current columns
  (`employment_type` / `job_title` / dates / `primary_department_uuid` /
  `work_location`), copying any per-locale `job_title` overrides out of the
  person's `translations` JSONB into the span's `translations`. Guarded by a
  `NOT EXISTS` check on the span table so a re-run is a safe no-op; people with
  no employment data at all are skipped (they start with an empty history).
  `primary_team_uuid` is left null on backfill — the person's team comes from the
  many-to-many `team_memberships`, which has no single "primary" to copy.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # 1. Employment spans — a person's employment history.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_employments (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      staff_person_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE,
      employment_type VARCHAR(50),
      job_title VARCHAR(255),
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      primary_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      primary_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      employment_start_date DATE,
      employment_end_date DATE,
      work_location VARCHAR(255),
      notes TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_employments_person_index
    ON #{p}phoenix_kit_staff_employments (staff_person_uuid)
    """)

    # At most one OPEN span (current employment) per person.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_employments_one_open_index
    ON #{p}phoenix_kit_staff_employments (staff_person_uuid)
    WHERE employment_end_date IS NULL
    """)

    # 2. Backfill one span per existing person from the current columns. Guarded
    #    by NOT EXISTS so a partial re-run is a no-op; people with no employment
    #    data are skipped. job_title per-locale overrides are lifted out of the
    #    person's translations JSONB into the span's translations (job_title only).
    execute("""
    INSERT INTO #{p}phoenix_kit_staff_employments
      (staff_person_uuid, employment_type, job_title, translations,
       primary_department_uuid, employment_start_date, employment_end_date, work_location)
    SELECT
      pers.uuid,
      pers.employment_type,
      pers.job_title,
      COALESCE(
        (SELECT jsonb_object_agg(lang, jsonb_build_object('job_title', submap->'job_title'))
         FROM jsonb_each(pers.translations) AS t(lang, submap)
         WHERE submap ? 'job_title'),
        '{}'::jsonb
      ),
      pers.primary_department_uuid,
      pers.employment_start_date,
      pers.employment_end_date,
      pers.work_location
    FROM #{p}phoenix_kit_staff_people pers
    WHERE (
        pers.employment_type IS NOT NULL
        OR pers.job_title IS NOT NULL
        OR pers.employment_start_date IS NOT NULL
        OR pers.employment_end_date IS NOT NULL
        OR pers.primary_department_uuid IS NOT NULL
        OR pers.work_location IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_staff_employments e
        WHERE e.staff_person_uuid = pers.uuid
      )
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '136'")
  end

  @doc """
  Drops the employments table.

  The denormalized `employment_*` / `job_title` / `work_location` columns on
  `phoenix_kit_staff_people` are left intact, so a rollback keeps each person's
  current employment data — only the history is lost.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_employments")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '135'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
