defmodule PhoenixKit.Migrations.Postgres.V135 do
  @moduledoc """
  V135: Structured staff skills.

  Replaces the free-text `phoenix_kit_staff_people.skills` column with a
  first-class, translatable `Skill` entity assigned to people many-to-many,
  each assignment carrying zero or more of the skill's own proficiency levels.
  Creates:

  - `phoenix_kit_staff_skills` — translatable skill (name + description +
    `translations` JSONB), globally unique by `lower(name)`. Carries its own
    **per-skill, translatable proficiency levels** in a `levels` JSONB array
    (each `{"id", "name", "translations"}`) plus an `allow_multiple_levels`
    boolean that decides whether an assignment may hold one level or several.
  - `phoenix_kit_staff_person_skills` — person ↔ skill join whose
    `proficiency_levels` JSONB array holds the selected level `id`s into the
    parent skill's `levels` (`[]` = no level / "not set")

  ## Data migration

  The free-text `skills` column (comma-separated) is split, trimmed,
  case-insensitively de-duplicated into `Skill` rows, and each person is
  linked to the skills parsed from their string (proficiency `NULL`). Then
  the column is dropped. The parse/insert runs inside a column-existence
  guard so a partial re-run (column already dropped) is a safe no-op.

  **Lossy by design (documented):** the column holds only the primary-language
  skill string. Per-locale skill overrides — `translations[locale]["skills"]`
  on the people table, a *separate* JSONB column — do **not** map cleanly to
  structured skills and are **dropped** (the orphaned `"skills"` keys are
  stripped from each person's `translations`). Structured skills carry their
  own translations going forward.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # 1. Skills entity (translatable, flat — no parent).
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_skills (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      levels JSONB NOT NULL DEFAULT '[]'::jsonb,
      allow_multiple_levels BOOLEAN NOT NULL DEFAULT false,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_skills_lower_name_index
    ON #{p}phoenix_kit_staff_skills (lower(name))
    """)

    # 2. person ↔ skill join + nullable proficiency level.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_person_skills (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      staff_person_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE,
      skill_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_skills(uuid) ON DELETE CASCADE,
      proficiency_levels JSONB NOT NULL DEFAULT '[]'::jsonb,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_person_skills_person_skill_index
    ON #{p}phoenix_kit_staff_person_skills (staff_person_uuid, skill_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_person_skills_skill_index
    ON #{p}phoenix_kit_staff_person_skills (skill_uuid)
    """)

    # 3. Migrate the free-text column → structured rows. Guarded on the
    #    column still existing so a retry after the DROP below is a no-op
    #    (PL/pgSQL plans the inner statements lazily, so they're never parsed
    #    when the column is gone). Prefix threaded through the dynamic SQL.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}'
          AND table_name = 'phoenix_kit_staff_people'
          AND column_name = 'skills'
      ) THEN
        -- distinct skills, deterministic canonical casing
        INSERT INTO #{p}phoenix_kit_staff_skills (name)
        SELECT DISTINCT ON (lower(trim(tok))) trim(tok)
        FROM #{p}phoenix_kit_staff_people pers
        CROSS JOIN LATERAL regexp_split_to_table(pers.skills, ',') AS tok
        WHERE pers.skills IS NOT NULL AND trim(tok) <> ''
        ORDER BY lower(trim(tok)), trim(tok)
        ON CONFLICT (lower(name)) DO NOTHING;

        -- link each person to the skills parsed from their string
        INSERT INTO #{p}phoenix_kit_staff_person_skills (staff_person_uuid, skill_uuid)
        SELECT DISTINCT pers.uuid, sk.uuid
        FROM #{p}phoenix_kit_staff_people pers
        CROSS JOIN LATERAL regexp_split_to_table(pers.skills, ',') AS tok
        JOIN #{p}phoenix_kit_staff_skills sk ON lower(sk.name) = lower(trim(tok))
        WHERE pers.skills IS NOT NULL AND trim(tok) <> ''
        ON CONFLICT (staff_person_uuid, skill_uuid) DO NOTHING;

        -- strip the now-orphaned per-locale "skills" overrides from the
        -- separate translations JSONB (idempotent: removing an absent key
        -- is a no-op; other translated fields are preserved)
        UPDATE #{p}phoenix_kit_staff_people pers
        SET translations = (
          SELECT COALESCE(jsonb_object_agg(lang, submap - 'skills'), '{}'::jsonb)
          FROM jsonb_each(pers.translations) AS t(lang, submap)
        )
        WHERE pers.translations <> '{}'::jsonb;
      END IF;
    END $$;
    """)

    # 4. Drop the free-text column (independently idempotent).
    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS skills")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '135'")
  end

  @doc """
  Drops the two skills tables and re-adds the free-text `skills` column.

  **Lossy rollback:** the re-added `skills` column is empty — structured
  skill rows and assignments are destroyed and the original free-text values
  are not restored.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_staff_people ADD COLUMN IF NOT EXISTS skills TEXT")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_person_skills")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_skills")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '134'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
