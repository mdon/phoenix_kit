defmodule PhoenixKit.Migrations.Postgres.V184 do
  @moduledoc """
  V184: `phoenix_kit_settings_history` — every change to a site setting,
  kept forever — and `phoenix_kit_posts.time_zone`, the zone a post was
  scheduled in.

  ## Why

  A stored instant does not say which regime wrote it. When the `time_zone`
  setting moved from an integer offset to an IANA id (2.13.9) and five
  modules turned out to have added that value to other instants, the rows
  they had written could not be repaired, because nothing recorded WHEN the
  setting changed or what it was before: `phoenix_kit_settings.date_updated`
  holds the last change only, and no writer logged to the activity feed —
  which prunes after 90 days anyway. The question "what was this setting at
  that instant?" had no answer.

  ## What it does

  One row per change: the key, the value before and after, who changed it
  (`actor_uuid`, nullable — a module or a migration is not a person; the FK
  sets it null when the account goes, the row stays), where the change came
  from (`source`: `settings` for the admin page, `system` otherwise) and
  when. Restricted (secret) settings record that a change HAPPENED with both
  values withheld (`restricted = true`), never the secret itself.

  Nothing prunes this table. Rolling back drops it — the history is lost
  with it.

  `phoenix_kit_posts.time_zone` (`varchar(64)`, nullable) is the same
  lesson applied to the one core-owned table that stores a typed wall clock:
  the posts module reads `scheduled_at` in the editor's zone, and a row that
  carries that zone can be re-resolved on its own. Rows written before this
  hold nil.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    Helpers.ensure_uuid_v7_function(prefix)
    uuid_default = Helpers.uuid_v7_call(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_settings_history (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      key CHARACTER VARYING(255) NOT NULL,
      old_value TEXT,
      new_value TEXT,
      restricted BOOLEAN NOT NULL DEFAULT false,
      actor_uuid UUID,
      source CHARACTER VARYING(64) NOT NULL DEFAULT 'system',
      inserted_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL
    )
    """)

    # Constraint existence is checked with a name-based `pg_class` +
    # `pg_namespace` JOIN, never `'schema.table'::regclass` — the cast raises
    # rather than answering false when the relation is absent (V180, V183).
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE c.conname = 'phoenix_kit_settings_history_actor_uuid_fkey'
           AND t.relname = 'phoenix_kit_settings_history'
           AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_settings_history
          ADD CONSTRAINT phoenix_kit_settings_history_actor_uuid_fkey
          FOREIGN KEY (actor_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    # "What was `key` at instant T" walks the key's rows by time.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_settings_history_key_inserted_at_index
      ON #{p}phoenix_kit_settings_history USING btree (key, inserted_at)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_posts
      ADD COLUMN IF NOT EXISTS time_zone character varying(64)
    """)

    # Single-step runs rely on the migration stamping its own marker — the
    # runner only writes it for multi-step ranges.
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '184'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # The history has no other home: a rollback DROPS it.
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_settings_history")

    execute("ALTER TABLE #{p}phoenix_kit_posts DROP COLUMN IF EXISTS time_zone")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '183'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
