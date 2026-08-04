defmodule PhoenixKit.Migrations.Postgres.V161 do
  @moduledoc """
  V161: Repair for the V56/V57 flush-order bug's fallout on already-migrated
  single-shot installs.

  ## Root cause (fixed at the source in V56/V57/V72; this version is the
  cleanup for installs that ran the buggy versions before those fixes)

  V56 called `UUIDFKColumns.up/1` (queues `ADD COLUMN` for ~80 `*_uuid` FK
  columns) immediately followed by `UUIDFKColumns.add_constraints/1` (whose
  `set_not_null/4` and `add_fk_constraint/7` guard themselves with immediate
  `column_exists?`/`table_exists?` `information_schema` queries) with no
  `flush()` between them, and V57 (which re-runs the same pair) had no
  `flush()` at all. On an incremental, one-version-at-a-time chain run
  (`mix phoenix_kit.update` against an existing install) this never
  mattered — Ecto's migrator flushes between migration modules regardless.
  On a **single-shot** chain run (a fresh `mix phoenix_kit.install`, or this
  repo's own squash-generator single-shot probe) the whole V1..V160 chain
  queues into one command buffer until something flushes it, so
  `add_constraints/1`'s guards ran against `information_schema` state that
  had not seen the columns `UUIDFKColumns.up/1` had *just* queued moments
  earlier in the same call — every guard failed closed, and ~46 `*_uuid`
  columns across ~33 tables were silently left nullable instead of NOT
  NULL. `phoenix_kit_comments.fk_comments_user_uuid` specifically was never
  created at all (the same guard gap). V72, running later and finding that
  FK genuinely missing, added it back with a guessed `ON DELETE CASCADE`
  instead of matching V56/V57's own already-declared `SET NULL` intent
  (`UUIDFKColumns.@fk_constraints`) — comments behave like tickets/
  ai_requests (orphaned-author rows survive, blanked), not like the
  `*_likes`/`*_dislikes` junction tables, which genuinely should vanish
  with their user.

  V56 and V57 now each have the missing `flush()`, and V72's entry is now
  `SET NULL` — so every chain run *from here on*, single-shot or
  incremental, produces the correct shape and this version is a no-op on
  it. This version exists only to repair installs whose single-shot run
  already happened before those fixes landed.

  ## What this does

  1. For every `{table, column}` pair `UUIDFKColumns.add_constraints/1`
     sets NOT NULL on (`UUIDFKColumns.not_null_uuid_fks/0` — the exact same
     list, not a second copy of it): if the column currently has zero NULL
     rows, sets NOT NULL — matching the shape a correctly-flushed V56/V57
     run would already have produced, a no-op if it's already NOT NULL. If
     NULL rows exist, this does **not** guess: those NULLs may be
     legitimate application data (e.g. an FK reference to a deleted row
     with no CASCADE, or a genuinely optional relation) rather than purely
     an artifact of the flush bug, so it raises a warning naming the
     table/column/row count and leaves the column nullable for an operator
     to investigate — never backfills a live column with a random value to
     force the constraint through (unlike `UUIDFKColumns`' own
     conversion-era backfill, which only ever ran against columns it had
     *just* created moments earlier in the same call, never live data).

  2. `phoenix_kit_comments.fk_comments_user_uuid`: if it currently has `ON
     DELETE CASCADE` (V72's guess, made under the buggy single-shot
     shape), drops and re-adds it `ON DELETE SET NULL`. No orphan cleanup
     is needed for that transition — rows cannot be orphaned under an
     already-enforced CASCADE constraint (every row whose referenced user
     was deleted would already be gone). If the constraint is absent
     entirely (defensive — V72 always runs before this version and its own
     add is itself existence-guarded, so this should not happen in
     practice), adds it `SET NULL` with the same orphan cleanup V72's own
     `add_fk_constraint/7` does. If already `SET NULL`, no-op.

  ## down/1

  This is a repair, not a feature — rolling back does not undo the NOT
  NULL constraints or the FK correction (same precedent as V57: "don't
  undo V56's work on rollback"). `down/1` only restamps the version
  comment.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.UUIDFKColumns

  @comments_table "phoenix_kit_comments"
  @comments_fk_column "user_uuid"
  @comments_constraint "fk_comments_user_uuid"
  @comments_ref_table "phoenix_kit_users"
  @comments_ref_column "uuid"

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # The immediate queries below (NULL counts, the comments-FK's
    # confdeltype) must see every column/constraint queued by earlier
    # versions in this same chain run — same reasoning as the flush now
    # added to V56/V57.
    flush()

    for {table, column} <- UUIDFKColumns.not_null_uuid_fks() do
      repair_not_null(table, column, prefix, escaped_prefix)
    end

    repair_comments_fk(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '161'")
  end

  def down(%{prefix: prefix} = _opts) do
    # Repair migration — never undoes the NOT NULL / FK correction on
    # rollback (V57's precedent: "don't undo V56's work"). Comment-restamp
    # only.
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '160'")
  end

  # ── NOT NULL repair ──────────────────────────────────────────────────

  defp repair_not_null(table, column, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, column, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      case null_count(table_name, column) do
        0 ->
          execute("""
          ALTER TABLE #{table_name}
          ALTER COLUMN #{column} SET NOT NULL
          """)

        :unknown ->
          IO.warn(
            "PhoenixKit V161: could not determine NULL count for #{table_str}.#{column} — " <>
              "leaving nullable."
          )

        count ->
          IO.warn(
            "PhoenixKit V161: #{table_str}.#{column} has #{count} NULL row(s) — leaving " <>
              "nullable (never backfilling live data). Investigate before enforcing NOT NULL."
          )
      end
    end
  end

  defp null_count(table_name, column) do
    case repo().query(
           "SELECT count(*) FROM #{table_name} WHERE #{column} IS NULL",
           [],
           log: false
         ) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> :unknown
    end
  end

  # ── Comments FK repair ────────────────────────────────────────────────

  defp repair_comments_fk(prefix, escaped_prefix) do
    if table_exists?(@comments_table, escaped_prefix) and
         column_exists?(@comments_table, @comments_fk_column, escaped_prefix) and
         table_exists?(@comments_ref_table, escaped_prefix) and
         column_exists?(@comments_ref_table, @comments_ref_column, escaped_prefix) do
      table_name = prefix_table_name(@comments_table, prefix)
      ref_name = prefix_table_name(@comments_ref_table, prefix)

      case comments_fk_on_delete(escaped_prefix) do
        "c" ->
          execute("ALTER TABLE #{table_name} DROP CONSTRAINT #{@comments_constraint}")
          add_comments_fk(table_name, ref_name)

        "n" ->
          :ok

        nil ->
          cleanup_orphaned_comments_fk_refs(table_name, ref_name)
          add_comments_fk(table_name, ref_name)

        other ->
          IO.warn(
            "PhoenixKit V161: #{@comments_constraint} has unexpected ON DELETE action " <>
              "#{inspect(other)} — leaving as-is."
          )
      end
    end
  end

  defp add_comments_fk(table_name, ref_name) do
    execute("""
    ALTER TABLE #{table_name}
    ADD CONSTRAINT #{@comments_constraint}
    FOREIGN KEY (#{@comments_fk_column})
    REFERENCES #{ref_name}(#{@comments_ref_column})
    ON DELETE SET NULL
    """)
  end

  # Mirrors V72's own add_fk_constraint/7 orphan cleanup — only reachable
  # in the defensive "constraint entirely absent" branch above.
  defp cleanup_orphaned_comments_fk_refs(table_name, ref_name) do
    execute("""
    DO $$
    DECLARE
      affected INTEGER;
    BEGIN
      UPDATE #{table_name} t
      SET #{@comments_fk_column} = NULL
      WHERE t.#{@comments_fk_column} IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM #{ref_name} r WHERE r.#{@comments_ref_column} = t.#{@comments_fk_column}
      );
      GET DIAGNOSTICS affected = ROW_COUNT;
      IF affected > 0 THEN
        RAISE NOTICE 'PhoenixKit V161: cleaned up % orphaned rows in %.%',
          affected, '#{table_name}', '#{@comments_fk_column}';
      END IF;
    END $$;
    """)
  end

  # Name-anchored pg_constraint + pg_class + pg_namespace JOIN — never a
  # `'<table>'::regclass` cast in an immediate check (CLAUDE.md's V146
  # 25P02 trap: it raises when the relation doesn't exist yet and aborts
  # the whole transaction).
  defp comments_fk_on_delete(escaped_prefix) do
    query = """
    SELECT c.confdeltype FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE c.conname = '#{@comments_constraint}'
      AND t.relname = '#{@comments_table}'
      AND n.nspname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[deltype]]}} -> deltype
      _ -> nil
    end
  end

  # ── Existence checks (same pattern as every other version file) ──────

  defp table_exists?(table, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table}'
      AND column_name = '#{column}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
