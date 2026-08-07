defmodule PhoenixKit.Migrations.Postgres.V163 do
  @moduledoc """
  V163: Repair for the V56/V57 flush-order bug's fallout on already-migrated
  single-shot installs.

  ## Root cause (fixed at the source in V56/V57/V72; this version is the
  cleanup for installs that ran the buggy versions before those fixes)

  V56 called `UUIDFKColumns.up/1` (queues `ADD COLUMN` for ~80 `*_uuid` FK
  columns) immediately followed by `UUIDFKColumns.add_constraints/1` (whose
  `set_not_null/4` and `add_fk_constraint/7` guard themselves with immediate
  `column_exists?`/`table_exists?` `information_schema` queries) with no
  `flush()` between them, and V57 (which re-runs the same pair) had no
  `flush()` at all. V56 and V57 are not separate Ecto migration modules —
  they are sub-calls inside one parent `up/1` that share a single command
  buffer — so ANY chain run crossing V56/V57 within one migrator invocation
  hits this, whether it came from a fresh `mix phoenix_kit.install` (one
  unpinned wrapper for the whole chain) or from an update wrapper whose
  range happens to span those versions. The buffer is not flushed by an
  immediate `repo().query`, so
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
     list, not a second copy of it) **minus `@relaxed_after_v57`** (below):
     if the column currently has zero NULL rows, sets NOT NULL — matching
     the shape a correctly-flushed V56/V57 run would already have
     produced, a no-op if it's already NOT NULL. If NULL rows exist, this
     does **not** guess: those NULLs may be legitimate application data
     (e.g. an FK reference to a deleted row with no CASCADE, or a
     genuinely optional relation) rather than purely an artifact of the
     flush bug, so it raises a warning naming the table/column/row count
     and leaves the column nullable for an operator to investigate — never
     backfills a live column with a random value to force the constraint
     through (unlike `UUIDFKColumns`' own conversion-era backfill, which
     only ever ran against columns it had *just* created moments earlier
     in the same call, never live data). Skipped columns (either via the
     warn path or via `@relaxed_after_v57`) stay nullable **by design** —
     re-running V163 is an idempotent restamp no-op, it does not retry
     them; a column an operator has since backfilled by
     hand is enforced with a one-line `ALTER TABLE ... SET NOT NULL`.

  ### `@relaxed_after_v57` — columns a LATER version deliberately made nullable again

  `not_null_uuid_fks/0` is V56/V57's own declared list — a snapshot of
  intent as of V57. Later versions can and do legitimately relax a column
  on that list for reasons that have nothing to do with the flush bug
  (V163 blindly re-enforcing NOT NULL on those would silently break
  whatever feature needed the relaxation — on a *fresh* install, the table
  starts empty, so the zero-NULL-rows check would not catch this at all).
  Found by grepping every `DROP NOT NULL` in `v58.ex`..`v162.ex` — after
  V57, where the flush fix landed — and intersecting the touched
  `{table, column}` pairs against `not_null_uuid_fks/0` (checked both raw
  SQL `ALTER COLUMN ... DROP NOT NULL` and the Ecto `modify ..., null:
  true` DSL form; only the former appears anywhere in this range):

    * `{:phoenix_kit_files, "user_uuid"}` — V113 (`v113.ex`): system-managed
      media rows (DZI tiles/manifests) have no human owner, only a
      `parent_file_uuid`; `phoenix_kit_files_user_or_parent_check` enforces
      "one of the two is set" at the CHECK-constraint level instead.
      Re-imposing NOT NULL here would break `Storage.store_system_file`'s
      tile generation on any install whose run hit the flush bug.

  The list also carries one entry that is not a later relaxation but a
  contradiction inside V56/V57's own declarations —
  `phoenix_kit_ticket_status_history.changed_by_uuid` is claimed by
  `@not_null_uuid_fks` while `@fk_constraints` gives its FK
  `ON DELETE SET NULL`, which NOT NULL makes unsatisfiable. See its inline
  comment; `uuid_fk_columns_test.exs` asserts no other pair contradicts.

  `test/phoenix_kit/migrations/v163_relaxed_columns_test.exs` statically
  scans `v58.ex`..the current HEAD version for this exact pattern and fails
  if it finds a `not_null_uuid_fks/0` member relaxed by a later version
  that is not listed here — a future relaxation cannot silently make this
  list stale again.

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

  # See the moduledoc section of the same name — a `not_null_uuid_fks/0`
  # member a LATER version deliberately dropped NOT NULL from again, so
  # V163 must not re-impose it. Exposed publicly so
  # `V163RelaxedColumnsTest` can assert this list stays a superset of every
  # `DROP NOT NULL` the chain applies to a tracked column after V57.
  @relaxed_after_v57 [
    # V113 (v113.ex): system-managed media rows have no human owner, only
    # a parent_file_uuid; phoenix_kit_files_user_or_parent_check enforces
    # "one of the two" at the CHECK-constraint level instead.
    {:phoenix_kit_files, "user_uuid"},
    # Not a later relaxation but a contradiction inside V56/V57's own two
    # lists: `@not_null_uuid_fks` claims this column, while `@fk_constraints`
    # declares its FK `ON DELETE SET NULL`. NOT NULL makes that FK
    # unsatisfiable — deleting a user who ever changed a ticket status would
    # fail with a not-null violation instead of blanking the author. On the
    # broken installs this repair targets the column is nullable, so user
    # deletion works today; enforcing NOT NULL would newly break it. Left
    # nullable until the chain resolves which of the two declarations is
    # wrong (`uuid_fk_columns_test.exs` asserts no OTHER pair contradicts).
    {:phoenix_kit_ticket_status_history, "changed_by_uuid"}
  ]

  @doc false
  def relaxed_after_v57, do: @relaxed_after_v57

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # The immediate queries below (NULL counts, the comments-FK's
    # confdeltype) must see every column/constraint queued by earlier
    # versions in this same chain run — same reasoning as the flush now
    # added to V56/V57.
    flush()

    # Serialization note: this whole migration (V163 included) runs inside
    # Ecto.Migrator.up/4's default `:table_lock` migration_lock strategy
    # (Ecto.Adapters.Postgres.lock_for_migrations/3 — not overridden
    # anywhere in this codebase), which wraps the entire run in one
    # transaction/lock. That closes the window between a column's
    # null_count/1 read below and its SET NOT NULL write against any
    # CONCURRENT migrator invocation on the same repo; it does not close
    # the window against ordinary application traffic concurrently
    # INSERTing a NULL into the same live column mid-migration — the same
    # deploy discipline (migrations run before the app starts serving
    # traffic) every other additive migration in this chain already
    # depends on for exactly this reason.
    for {table, column} <- UUIDFKColumns.not_null_uuid_fks() -- @relaxed_after_v57 do
      repair_not_null(table, column, prefix, escaped_prefix)
    end

    repair_comments_fk(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '163'")
  end

  def down(%{prefix: prefix} = _opts) do
    # Repair migration — never undoes the NOT NULL / FK correction on
    # rollback (V57's precedent: "don't undo V56's work"). Comment-restamp
    # only.
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '162'")
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
            "PhoenixKit V163: could not determine NULL count for #{table_str}.#{column} — " <>
              "leaving nullable. This column stays nullable by design (re-running V163 will " <>
              "not retry it, it is an idempotent restamp no-op) — apply ALTER TABLE ... " <>
              "ALTER COLUMN ... SET NOT NULL by hand once the cause is understood."
          )

        count ->
          IO.warn(
            "PhoenixKit V163: #{table_str}.#{column} has #{count} NULL row(s) — leaving " <>
              "nullable (never backfilling live data). Investigate before enforcing NOT NULL. " <>
              "This column stays nullable by design (re-running V163 will not retry it, it is " <>
              "an idempotent restamp no-op) — apply ALTER TABLE ... ALTER COLUMN ... SET " <>
              "NOT NULL by hand once the NULL rows are resolved."
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
          # DROP + ADD as two separate execute/1 calls, not one statement —
          # there is no established precedent anywhere in this chain for
          # combining multiple DDL statements into a single execute/1 (the
          # codebase's existing idiom for "must be atomic" is a single
          # statement guarded by a DO $$ IF NOT EXISTS $$ block, not
          # multiple statements in one call), so this keeps that
          # convention rather than introduce a new, unverified one.
          # Two-statement window is real: a constraint check racing
          # between the DROP and the ADD would see the FK briefly absent.
          # Acceptable here because (a) this is a metadata-only repair on
          # an already-CASCADE-enforced column — no row can be orphaned in
          # that window, and (b) it runs inside the same migration-wide
          # transaction/lock discussed on `up/1` above (a DIRECT
          # connection only — repair/migrations must never run through
          # PgBouncer, CLAUDE.md: it silently drops transactional DDL
          # while still recording the migration as applied).
          execute("ALTER TABLE #{table_name} DROP CONSTRAINT #{@comments_constraint}")
          add_comments_fk(table_name, ref_name)

        "n" ->
          :ok

        nil ->
          cleanup_orphaned_comments_fk_refs(table_name, ref_name)
          add_comments_fk(table_name, ref_name)

        other ->
          IO.warn(
            "PhoenixKit V163: #{@comments_constraint} has unexpected ON DELETE action " <>
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
        RAISE NOTICE 'PhoenixKit V163: cleaned up % orphaned rows in %.%',
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
