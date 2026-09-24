defmodule PhoenixKit.Migrations.Postgres.V203 do
  @moduledoc """
  V203: storage libraries, user libraries (phase 2 of
  `dev_docs/plans/2026-09-22-storage-libraries.md`).

    * `phoenix_kit_storage_library_members` — who else may use a user
      library, and as what (`manager` | `contributor` | `viewer`). The
      owner is the library's `owner_uuid`, never a member row. A member row
      goes with its library and with its user.
    * **Deleting a user no longer deletes their files.** The uploader FK
      `fk_files_user_uuid` moves from `ON DELETE CASCADE` to `SET NULL`, and
      `phoenix_kit_files_user_or_parent_check` accepts a file that has a
      library instead (every file has one since V202). Their uploads in the
      site's libraries and in other people's stay, with no uploader. The
      media-folder creator FK moves to `SET NULL` too: with no `ON DELETE`
      it refused to delete anyone who had ever created a folder.
    * **A user's own libraries must be trashed before the user goes.** The
      library owner FK moves from `RESTRICT` to `SET NULL`, and the owner
      check allows a user library without an owner only once it is trashed.
      Deleting a user whose live library still names them fails on that
      check, so the step `Auth.delete_user/2` takes first (trash every
      library they own) cannot be skipped, and a trashed library outlives
      its owner until the purge job empties it.
    * The library slug statements again, from V202 (#871): a database that
      ran an earlier build of V202 is marked 202 without the `slug` column.
      They are idempotent, so everywhere else they change nothing.

  Deliberately NOT here: dedup per library needs no schema change. A file
  in a library other than Media gets a `user_file_checksum` that folds the
  library in, so the existing unique index already holds one copy per
  uploader per library, and Media's keys are the ones every existing row
  has (`Storage.user_file_checksum/3`). V200's user-keyed capture-date
  index stays (the schema manifest cannot say "removed in version N" yet).

  ## Locks

  Every FK and CHECK is replaced only while it still has its old shape, so
  a re-run changes nothing. The new one is added `NOT VALID` under a
  temporary name, validated in a statement of its own (a `SHARE UPDATE
  EXCLUSIVE` scan: reads and writes go on), and then swapped in for the old
  one. Each validation scans its table once.

  Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V202

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V203 back: drops the members table and puts the uploader, folder
  creator and library owner FKs and their checks back as V202 had them.
  Files whose uploader has been deleted since cannot satisfy the old check;
  the rollback refuses (the CHECK fails) rather than delete them. The slug
  stays — it is V202's.
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name. Index names stay bare on CREATE; every existence check
  # is anchored to the schema.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    V202.slug_statements(prefix) ++
      List.flatten([
        """
        CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_storage_library_members (
          library_uuid uuid NOT NULL,
          user_uuid uuid NOT NULL,
          role character varying(20) DEFAULT 'viewer' NOT NULL,
          inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
          updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
          CONSTRAINT phoenix_kit_storage_library_members_pkey PRIMARY KEY (library_uuid, user_uuid),
          CONSTRAINT phoenix_kit_storage_library_members_library_uuid_fkey FOREIGN KEY (library_uuid)
            REFERENCES #{p}phoenix_kit_storage_libraries(uuid) ON DELETE CASCADE,
          CONSTRAINT phoenix_kit_storage_library_members_user_uuid_fkey FOREIGN KEY (user_uuid)
            REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
          CONSTRAINT phoenix_kit_storage_library_members_role_check
            CHECK (role IN ('manager', 'contributor', 'viewer'))
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS phoenix_kit_storage_library_members_user_uuid_index
        ON #{p}phoenix_kit_storage_library_members (user_uuid)
        """,
        replace_constraint(
          p,
          prefix,
          "phoenix_kit_files",
          "fk_files_user_uuid",
          "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL",
          "c.confdeltype <> 'n'"
        ),
        replace_constraint(
          p,
          prefix,
          "phoenix_kit_files",
          "phoenix_kit_files_user_or_parent_check",
          "CHECK (user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL OR library_uuid IS NOT NULL)",
          "pg_get_constraintdef(c.oid) NOT LIKE '%library_uuid%'"
        ),
        replace_constraint(
          p,
          prefix,
          "phoenix_kit_media_folders",
          "phoenix_kit_media_folders_user_uuid_fkey",
          "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL",
          "c.confdeltype <> 'n'"
        ),
        replace_constraint(
          p,
          prefix,
          "phoenix_kit_storage_libraries",
          "phoenix_kit_storage_libraries_owner_uuid_fkey",
          "FOREIGN KEY (owner_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL",
          "c.confdeltype <> 'n'"
        ),
        replace_constraint(
          p,
          prefix,
          "phoenix_kit_storage_libraries",
          "phoenix_kit_storage_libraries_owner_check",
          "CHECK ((kind = 'system' AND owner_uuid IS NULL) OR " <>
            "(kind = 'user' AND (owner_uuid IS NOT NULL OR trashed_at IS NOT NULL)))",
          "pg_get_constraintdef(c.oid) NOT LIKE '%trashed_at%'"
        ),
        "COMMENT ON TABLE #{p}phoenix_kit IS '203'"
      ])
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    List.flatten([
      replace_constraint(
        p,
        prefix,
        "phoenix_kit_storage_libraries",
        "phoenix_kit_storage_libraries_owner_check",
        "CHECK ((kind = 'system' AND owner_uuid IS NULL) OR (kind = 'user' AND owner_uuid IS NOT NULL))",
        "pg_get_constraintdef(c.oid) LIKE '%trashed_at%'"
      ),
      replace_constraint(
        p,
        prefix,
        "phoenix_kit_storage_libraries",
        "phoenix_kit_storage_libraries_owner_uuid_fkey",
        "FOREIGN KEY (owner_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE RESTRICT",
        "c.confdeltype <> 'r'"
      ),
      replace_constraint(
        p,
        prefix,
        "phoenix_kit_media_folders",
        "phoenix_kit_media_folders_user_uuid_fkey",
        "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid)",
        "c.confdeltype <> 'a'"
      ),
      replace_constraint(
        p,
        prefix,
        "phoenix_kit_files",
        "phoenix_kit_files_user_or_parent_check",
        "CHECK (((user_uuid IS NOT NULL) OR (parent_file_uuid IS NOT NULL)))",
        "pg_get_constraintdef(c.oid) LIKE '%library_uuid%'"
      ),
      replace_constraint(
        p,
        prefix,
        "phoenix_kit_files",
        "fk_files_user_uuid",
        "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE",
        "c.confdeltype <> 'c'"
      ),
      "DROP TABLE IF EXISTS #{p}phoenix_kit_storage_library_members",
      "COMMENT ON TABLE #{p}phoenix_kit IS '202'"
    ])
  end

  # Replaces constraint `name` on `table` with `definition`, but only while
  # the existing one matches `stale` (a condition on `pg_constraint c`), so a
  # re-run, or a database already in the new shape, is left alone; one
  # missing the constraint entirely gets it too. Three statements, each its
  # own transaction (the update wrappers disable the DDL transaction):
  #
  #   1. the new rule is added NOT VALID under a temporary name — a brief
  #      exclusive lock, no scan;
  #   2. it is validated — the scan, under `SHARE UPDATE EXCLUSIVE`, so
  #      reads and writes go on;
  #   3. the old rule is dropped and the new one takes its name.
  #
  # The table is never without the rule, and a run stopped between steps
  # picks up where it left off: steps 2 and 3 act on the temporary one
  # whenever it exists. Checked by name through pg_class + pg_namespace,
  # never `'…'::regclass`, which raises when the relation is missing.
  defp replace_constraint(p, prefix, table, name, definition, stale) do
    tmp = String.slice(name, 0, 50) <> "_v203"

    [
      """
      DO $$
      DECLARE
        stale_shape boolean;
      BEGIN
        IF #{exists_sql(prefix, table, tmp)} THEN
          RETURN;
        END IF;

        SELECT (#{stale}) INTO stale_shape
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}';

        IF stale_shape IS DISTINCT FROM false THEN
          ALTER TABLE #{p}#{table} ADD CONSTRAINT #{tmp} #{definition} NOT VALID;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF #{exists_sql(prefix, table, tmp)} THEN
          ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT #{tmp};
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF #{exists_sql(prefix, table, tmp)} THEN
          ALTER TABLE #{p}#{table} DROP CONSTRAINT IF EXISTS #{name};
          ALTER TABLE #{p}#{table} RENAME CONSTRAINT #{tmp} TO #{name};
        END IF;
      END
      $$
      """
    ]
  end

  defp exists_sql(prefix, table, name) do
    "EXISTS (SELECT 1 FROM pg_constraint c " <>
      "JOIN pg_class t ON t.oid = c.conrelid " <>
      "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
      "WHERE c.conname = '#{name}' AND t.relname = '#{table}' AND n.nspname = '#{prefix}')"
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
