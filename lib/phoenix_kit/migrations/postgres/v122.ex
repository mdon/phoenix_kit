defmodule PhoenixKit.Migrations.Postgres.V122 do
  @moduledoc """
  V122: Make the `(name, parent_uuid)` unique index on
  `phoenix_kit_media_folders` partial — restrict to non-trashed rows.

  Without `WHERE trashed_at IS NULL`, a soft-deleted "untitled" folder
  in trash still reserves its slot in the index, blocking re-creation
  of the same name in the same parent. The trash bucket is invisible
  to the user, so the collision surfaces as either "Failed to create
  folder" (when the chosen name happens to land on a trashed sibling)
  or as an unhelpful jump in the auto-numbering (e.g. "untitled 3"
  when the user sees an empty parent). Restricting the index to
  active rows resolves both: trashed folders no longer reserve names,
  and `Storage.list_folders/2` (active-only) is now an accurate
  predictor of what the constraint will accept.

  The `COALESCE(parent_uuid, '00000000-...')` expression is preserved
  so root-level rows (NULL parent) still cluster under a single
  group — without it PostgreSQL's default NULLS-DISTINCT semantics
  would let multiple identically-named root folders coexist.

  Idempotent: each step guards on prior state.
  """

  use Ecto.Migration

  # PostgreSQL disallows schema-qualifying the index name in
  # `CREATE INDEX` (the index always lands in the table's schema),
  # so the index name is bare while the table reference carries the
  # prefix. `DROP INDEX` does accept the qualifier — it's kept there
  # so cross-prefix installs don't accidentally drop another schema's
  # index of the same name.
  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_media_folders_name_parent_idx")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_media_folders_name_parent_idx
    ON #{p}phoenix_kit_media_folders (name, COALESCE(parent_uuid, '00000000-0000-0000-0000-000000000000'))
    WHERE trashed_at IS NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '122'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_media_folders_name_parent_idx")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_media_folders_name_parent_idx
    ON #{p}phoenix_kit_media_folders (name, COALESCE(parent_uuid, '00000000-0000-0000-0000-000000000000'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '121'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
