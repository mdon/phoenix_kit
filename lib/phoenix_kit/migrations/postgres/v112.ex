defmodule PhoenixKit.Migrations.Postgres.V112 do
  @moduledoc """
  V112: Add `archived_at` to `phoenix_kit_projects`.

  Replaces the dual-purpose `status` field (which held both lifecycle
  state and a soft-hide flag) with a dedicated nullable timestamp.
  Mirrors the workspace convention used by `phoenix_kit_publishing`'s
  `posts.trashed_at` and `phoenix_kit_files.trashed_at` — null = visible,
  non-null = soft-hidden, with the timestamp doubling as audit metadata.

  ## Why not drop `status`?

  The column is preserved for now (intentional — see
  `phoenix_kit_projects/AGENTS.md`) so a future workflow concept that
  legitimately wants a string lifecycle state (e.g. "paused", "blocked",
  "on_hold") can reuse the column without another migration. Application
  code stops reading or writing it; existing rows whose `status` is
  `"archived"` get backfilled into `archived_at` so the dashboard
  filters keep working transparently.

  Idempotent: re-running the migration is a no-op once `archived_at`
  exists.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # 1. Add the column if missing.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_projects'
          AND column_name = 'archived_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_projects
          ADD COLUMN archived_at TIMESTAMP(0);
      END IF;
    END $$;
    """)

    # 2. Backfill: any project currently `status='archived'` whose
    #    `archived_at` is unset gets stamped with `updated_at`. This
    #    preserves the soft-hide state when application code stops
    #    looking at `status`.
    execute("""
    UPDATE #{p}phoenix_kit_projects
       SET archived_at = COALESCE(updated_at, NOW())
     WHERE status = 'archived'
       AND archived_at IS NULL;
    """)

    # 3. Index — dashboard queries default to `is_nil(archived_at)`,
    #    so a partial index on the visible set keeps them sub-millisecond
    #    even on large project tables. Mirrors the partial-index pattern
    #    used elsewhere in core.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_projects'
          AND indexname = 'phoenix_kit_projects_visible_idx'
      ) THEN
        CREATE INDEX phoenix_kit_projects_visible_idx
          ON #{p}phoenix_kit_projects (inserted_at DESC)
          WHERE archived_at IS NULL;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '112'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_visible_idx")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS archived_at")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '111'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
