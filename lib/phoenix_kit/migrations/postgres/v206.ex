defmodule PhoenixKit.Migrations.Postgres.V206 do
  @moduledoc """
  V206: user-owned storage, the schema half (`dev_docs/plans/2026-09-22-storage-libraries.md`,
  "Next: V206").

  A user may keep a library's bytes in their own S3-compatible bucket. Two
  nullable columns say whose:

    * `phoenix_kit_buckets.owner_uuid` and
      `phoenix_kit_storage_profiles.owner_uuid` — NULL is the site's (every
      bucket and profile that exists today). A non-NULL one is a user's, and
      `Storage.list_buckets/0`, `Storage.list_enabled_buckets/0` and
      `Storage.Profiles.list_profiles/0` leave it out, so nothing that
      enumerates the site's storage ever sees it.

  **`owner_uuid` has no foreign key, on purpose.** `ON DELETE SET NULL` would
  turn a deleted user's bucket, credentials and all, into a site bucket in the
  shared pool; `RESTRICT` would block deleting a user. A dangling owner is
  inert: the owner's libraries are purged and their buckets and profiles
  removed with them.

  One check keeps an owned bucket safe whatever the application does:

    * `phoenix_kit_buckets_owned_check` — `owner_uuid IS NULL OR
      (provider <> 'local' AND integration_uuid IS NOT NULL)`. A user bucket is
      never a filesystem path (that would be arbitrary write access on the
      server) and never carries keys of its own (they live in the user's
      personal Integrations connection).

  Nothing is copied, moved or rewritten, and every existing row has a NULL
  owner, so the check holds for all of them.

  ## Locks

  Two nullable columns without defaults are metadata-only; the partial indexes
  cover no existing row; the check is added `NOT VALID` and validated over a
  handful of bucket rows. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @check "phoenix_kit_buckets_owned_check"

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V206 back. A user-owned bucket or profile cannot exist without the
  column, so they are removed first, after the library rows that point at the
  profiles: those libraries go back to the Default profile.
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_buckets ADD COLUMN IF NOT EXISTS owner_uuid uuid",
      "ALTER TABLE #{p}phoenix_kit_storage_profiles ADD COLUMN IF NOT EXISTS owner_uuid uuid",
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_buckets_owner_uuid_index
      ON #{p}phoenix_kit_buckets (owner_uuid)
      WHERE owner_uuid IS NOT NULL
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_storage_profiles_owner_uuid_index
      ON #{p}phoenix_kit_storage_profiles (owner_uuid)
      WHERE owner_uuid IS NOT NULL
      """,
      add_constraint(
        p,
        prefix,
        "phoenix_kit_buckets",
        @check,
        "CHECK (owner_uuid IS NULL OR (provider <> 'local' AND integration_uuid IS NOT NULL))"
      ),
      "ALTER TABLE #{p}phoenix_kit_buckets VALIDATE CONSTRAINT #{@check}",
      "COMMENT ON TABLE #{p}phoenix_kit IS '206'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      # Libraries on a user's profile go back to the Default (NULL), then the
      # user's rows go. The profile rows of a bucket go with it (their FK is
      # RESTRICT, so they are removed first), and a bucket that still holds
      # file locations is left to fail loudly rather than lose its record.
      """
      UPDATE #{p}phoenix_kit_storage_libraries
      SET storage_profile_uuid = NULL
      WHERE storage_profile_uuid IN (
        SELECT uuid FROM #{p}phoenix_kit_storage_profiles WHERE owner_uuid IS NOT NULL
      )
      """,
      """
      DELETE FROM #{p}phoenix_kit_storage_profile_buckets
      WHERE profile_uuid IN (
        SELECT uuid FROM #{p}phoenix_kit_storage_profiles WHERE owner_uuid IS NOT NULL
      )
      OR bucket_uuid IN (
        SELECT uuid FROM #{p}phoenix_kit_buckets WHERE owner_uuid IS NOT NULL
      )
      """,
      "DELETE FROM #{p}phoenix_kit_storage_profiles WHERE owner_uuid IS NOT NULL",
      "DELETE FROM #{p}phoenix_kit_buckets WHERE owner_uuid IS NOT NULL",
      "ALTER TABLE #{p}phoenix_kit_buckets DROP CONSTRAINT IF EXISTS #{@check}",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_storage_profiles_owner_uuid_index",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_buckets_owner_uuid_index",
      "ALTER TABLE #{p}phoenix_kit_storage_profiles DROP COLUMN IF EXISTS owner_uuid",
      "ALTER TABLE #{p}phoenix_kit_buckets DROP COLUMN IF EXISTS owner_uuid",
      "COMMENT ON TABLE #{p}phoenix_kit IS '205'"
    ]
  end

  # Adds a constraint `NOT VALID` unless the table already has one of that
  # name (checked through pg_class + pg_namespace, never `::regclass`).
  defp add_constraint(p, prefix, table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}#{table} ADD CONSTRAINT #{name} #{definition} NOT VALID;
      END IF;
    END
    $$
    """
  end
end
