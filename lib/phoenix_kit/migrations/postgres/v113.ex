defmodule PhoenixKit.Migrations.Postgres.V113 do
  @moduledoc """
  V113: System-managed media flag + source-parent link for Tessera tiles,
  plus the comments ↔ files attachment junction table.

  Adds two columns to `phoenix_kit_files`:

    * `system_managed :: boolean, default false, not null` — when true, the
      File represents internally-generated media (DZI tile pyramids and
      their per-tile chunks). System-managed files are excluded from the
      user-facing MediaBrowser listings and skip the variant generation
      pipeline (no small / medium / large produced — they only get an
      `"original"` FileInstance, since they don't need quality variants).

    * `parent_file_uuid :: uuid, nullable` — FK to `phoenix_kit_files.uuid`
      for system-managed children, pointing at the source file the chunk
      was derived from. Lets us cascade-clean tiles when the source image
      is deleted, and lets us list all tiles for a given source for
      auditing / re-generation.

  Index on `(parent_file_uuid)` for the cascade-delete + per-source queries.
  Partial index on `system_managed = true` keeps the MediaBrowser's
  "WHERE NOT system_managed" filter cheap as the tile catalog grows.

  Also creates `phoenix_kit_comment_media` — a junction table that lets the
  comments module attach core File rows to individual comments with a
  caller-supplied ordering and optional caption:

    * `comment_uuid` FK → `phoenix_kit_comments(uuid)` `ON DELETE :delete_all`
      (deleting the comment removes its attachment rows).
    * `file_uuid`    FK → `phoenix_kit_files(uuid)`    `ON DELETE :restrict`
      (a file can't be hard-deleted while it's still attached to a comment;
      the comments module manages the unlink lifecycle).
    * `position` integer — caller-managed ordering inside a comment.
    * `caption`  text, nullable.

  Unique index on `(comment_uuid, position)` so each slot in a comment is
  occupied at most once. Per-file index on `file_uuid` for reverse lookup
  ("which comments reference this file?").

  ## Concurrent-generation safety

  Two additional safeguards keep concurrent lazy-generation requests from
  producing duplicate `phoenix_kit_files` rows or violating the
  "user_uuid OR parent_file_uuid" invariant:

    * `phoenix_kit_files_system_dedup_index` — partial unique index on
      `(parent_file_uuid, file_name)` where `system_managed = true`. Lets
      `Storage.store_system_file/3` use `ON CONFLICT DO NOTHING` so a
      racing second writer for the same tile silently returns the
      existing row.

    * `phoenix_kit_files_user_or_parent_check` — DB-level CHECK
      constraint enforcing `user_uuid IS NOT NULL OR parent_file_uuid
      IS NOT NULL`. The schema's `validate_system_managed_invariants`
      is the user-facing check; this constraint is the safety net for
      raw inserts, `Repo.insert_all`, or external tools.

  All column / FK / NOT-NULL changes use raw SQL with explicit
  `IF NOT EXISTS` / `DO $$ … END $$` guards so re-running on a
  partially-applied schema is a no-op.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # All column / FK / NOT-NULL changes use raw SQL with explicit IF NOT
    # EXISTS / DO-block guards so re-running the migration on a partially-
    # applied schema is a no-op. Ecto's `add_if_not_exists` only protects
    # the column itself, not the FK constraint or the NOT NULL drop —
    # those would crash on a second run.

    execute(
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS system_managed BOOLEAN NOT NULL DEFAULT false"
    )

    execute("ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS parent_file_uuid UUID")

    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_files_parent_file_uuid_fkey'
        AND conrelid = '#{p}phoenix_kit_files'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_files
          ADD CONSTRAINT phoenix_kit_files_parent_file_uuid_fkey
          FOREIGN KEY (parent_file_uuid)
          REFERENCES #{p}phoenix_kit_files(uuid)
          ON DELETE CASCADE;
      END IF;
    END $$
    """)

    # System-managed rows (Tessera tile chunks) don't have a user owner —
    # they belong to a parent File via `parent_file_uuid`. Drop NOT NULL
    # on `user_uuid` so the constraint isn't violated; the changeset's
    # `validate_system_managed_invariants` enforces "user_uuid OR
    # parent_file_uuid is set" at the application level. `DROP NOT NULL`
    # is itself idempotent on a column that's already nullable.
    execute("ALTER TABLE #{p}phoenix_kit_files ALTER COLUMN user_uuid DROP NOT NULL")

    # Per-source tile lookup + cascade-cleanup index. Only meaningful for
    # tile rows; partial on NOT NULL keeps the index tight.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_files_parent_uuid_index
    ON #{p}phoenix_kit_files (parent_file_uuid)
    WHERE parent_file_uuid IS NOT NULL
    """)

    # Cheap "show me only user files" filter for MediaBrowser.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_files_system_managed_index
    ON #{p}phoenix_kit_files (inserted_at DESC)
    WHERE system_managed = false
    """)

    # Idempotent dedup on (parent_file_uuid, file_name) for system-managed
    # rows. Tiles + manifests are keyed by parent_file_uuid + on-bucket
    # path; concurrent lazy-generation requests for the same uncached tile
    # used to be able to produce duplicate File rows (the Manager.file_exists?
    # check raced with the bucket write). This partial unique index turns
    # that into a DB-level no-op via `ON CONFLICT DO NOTHING` in
    # Storage.store_system_file/3.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_files_system_dedup_index
    ON #{p}phoenix_kit_files (parent_file_uuid, file_name)
    WHERE system_managed = true
    """)

    # DB-level enforcement of the application invariant that every File row
    # has either a human owner (`user_uuid`) or a system parent
    # (`parent_file_uuid`). The schema's `validate_system_managed_invariants`
    # is the user-facing check; this CHECK constraint keeps raw inserts,
    # `Repo.insert_all`, or external tools from silently breaking the
    # invariant. NOT VALID on the ADD so existing rows don't have to be
    # re-scanned (we follow with `VALIDATE CONSTRAINT` which only checks
    # incoming writes after).
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_files_user_or_parent_check'
        AND conrelid = '#{p}phoenix_kit_files'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_files
          ADD CONSTRAINT phoenix_kit_files_user_or_parent_check
          CHECK (user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL)
          NOT VALID;
        ALTER TABLE #{p}phoenix_kit_files
          VALIDATE CONSTRAINT phoenix_kit_files_user_or_parent_check;
      END IF;
    END $$
    """)

    # Comments ↔ files attachment junction. Lives in core (not the comments
    # module) because the files side is core. Comments owns the unlink
    # lifecycle — `ON DELETE :restrict` on `file_uuid` blocks a file's hard
    # delete while attachments exist; comments must detach first.
    create_if_not_exists table(:phoenix_kit_comment_media,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        default: fragment("uuid_generate_v7()"),
        null: false
      )

      add(
        :comment_uuid,
        references(:phoenix_kit_comments,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :restrict,
          prefix: prefix
        ),
        null: false
      )

      add(:position, :integer, null: false)
      add(:caption, :text)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_comment_media, [:comment_uuid, :position],
        name: :phoenix_kit_comment_media_comment_position_index,
        prefix: prefix
      )
    )

    create_if_not_exists(index(:phoenix_kit_comment_media, [:file_uuid], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '113'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_comment_media, prefix: prefix))

    # Drop the CHECK + dedup index BEFORE dropping the columns they
    # reference — order matters; PG won't let you drop a column with a
    # live CHECK that references it.
    execute(
      "ALTER TABLE #{p}phoenix_kit_files DROP CONSTRAINT IF EXISTS phoenix_kit_files_user_or_parent_check"
    )

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_files_system_dedup_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_files_system_managed_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_files_parent_uuid_index")

    # Tile rows have null user_uuid; clear them before restoring NOT NULL.
    execute("DELETE FROM #{p}phoenix_kit_files WHERE system_managed = true")

    # Drop FK before the column so the constraint name is freed for a
    # future re-up. Both guarded so a partially-rolled-back schema doesn't
    # crash here.
    execute(
      "ALTER TABLE #{p}phoenix_kit_files DROP CONSTRAINT IF EXISTS phoenix_kit_files_parent_file_uuid_fkey"
    )

    execute("ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS parent_file_uuid")
    execute("ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS system_managed")

    execute("ALTER TABLE #{p}phoenix_kit_files ALTER COLUMN user_uuid SET NOT NULL")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '112'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
