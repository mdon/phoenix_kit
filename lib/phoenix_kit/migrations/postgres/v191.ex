defmodule PhoenixKit.Migrations.Postgres.V191 do
  @moduledoc """
  V191: who added a user.

  Adds `phoenix_kit_users.created_by_uuid uuid NULL` — the account that
  created this user by hand from the admin panel. `NULL` means the user
  signed themselves up (registration form, magic link, OAuth, guest
  checkout), or was added before this column existed and left no trace.

    * **Foreign key, `ON DELETE SET NULL`** — the same shape as
      `organization_uuid`. Deleting the admin who added someone must not
      delete, or block deleting, the people they added.
    * **Index** — `ON DELETE SET NULL` makes Postgres look up every row
      pointing at a deleted user; without one that is a full scan of
      `phoenix_kit_users` per user deletion.
    * **Backfill** — the admin form has logged a `user.created` activity
      with `metadata.method = 'manual'` and the creating admin as
      `actor_uuid` since the Activity feed shipped. Those entries seed the
      column, so users added before this version still show who added
      them — as far back as `activity_retention_days` kept the entry. Only
      an actor that still exists is copied, and a value already present is
      never overwritten, so the statement is safe to re-run.

  The column is written only by `PhoenixKit.Users.Auth.admin_create_user/2`
  and is never cast from params: a public registration form cannot claim to
  have been added by someone.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")

    Enum.each(up_statements(prefix), &execute/1)
  end

  @doc """
  Rolls V191 back: drops the column (its index and foreign key go with it).

  **Lossy:** who added each user is lost, except for what the Activity feed
  still holds.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")

    Enum.each(down_statements(prefix), &execute/1)
  end

  # Public so the suite can run the REAL statements — `up/1` can't be invoked
  # outside an `Ecto.Migrator` runner (same constraint as V189Test and
  # friends). `prefix` is the bare schema name.
  @doc false
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      """
      ALTER TABLE #{p}phoenix_kit_users
      ADD COLUMN IF NOT EXISTS created_by_uuid uuid
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_users_created_by_uuid_fkey'
            AND t.relname = 'phoenix_kit_users'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_users ADD CONSTRAINT phoenix_kit_users_created_by_uuid_fkey FOREIGN KEY (created_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_users_created_by_uuid_index
      ON #{p}phoenix_kit_users USING btree (created_by_uuid)
      """,
      """
      UPDATE #{p}phoenix_kit_users AS u
      SET created_by_uuid = s.actor_uuid
      FROM (
        SELECT DISTINCT ON (a.resource_uuid) a.resource_uuid, a.actor_uuid
        FROM #{p}phoenix_kit_activities AS a
        JOIN #{p}phoenix_kit_users AS actor ON actor.uuid = a.actor_uuid
        WHERE a.action = 'user.created'
          AND a.metadata->>'method' = 'manual'
          AND a.resource_uuid IS NOT NULL
          AND a.actor_uuid <> a.resource_uuid
        ORDER BY a.resource_uuid, a.inserted_at
      ) AS s
      WHERE u.uuid = s.resource_uuid
        AND u.created_by_uuid IS NULL
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '191'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_users DROP COLUMN IF EXISTS created_by_uuid",
      "COMMENT ON TABLE #{p}phoenix_kit IS '190'"
    ]
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
