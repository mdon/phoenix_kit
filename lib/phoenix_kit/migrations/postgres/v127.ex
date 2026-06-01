defmodule PhoenixKit.Migrations.Postgres.V127 do
  @moduledoc """
  V127: Sub-projects as tasks (`phoenix_kit_project_assignments.child_project_uuid`).

  Lets a project be embedded inside another project as one of its task rows.
  A sub-project is an `Assignment` that points at a child `Project` instead of
  a reusable `Task` template — so it lives in the parent's task timeline and
  gets dependencies + drag-reorder for free (both are already assignment-level
  and project-scoped). The child project is the single source of truth; the
  parent's linking assignment carries denormalized rollup fields (status /
  progress_pct / estimated_duration / completed_at) synced by the context layer
  whenever the child changes, so every existing read site (schedule math,
  `recompute_project_completion`, dashboards, sorting) keeps working unchanged.

  Changes to `phoenix_kit_project_assignments`:

    * `child_project_uuid UUID` → FK `phoenix_kit_projects(uuid) ON DELETE RESTRICT`.
      `RESTRICT` (not `CASCADE`) so a stray child-project delete fails loudly
      instead of silently mutating the parent's task list — recursive teardown
      is orchestrated explicitly in `PhoenixKitProjects.Projects` inside a
      transaction so it can log activity and tear the subtree down in order.
    * `task_uuid` loses its `NOT NULL` — a sub-project assignment has no template.
    * `CHECK ((task_uuid IS NOT NULL) <> (child_project_uuid IS NOT NULL))` —
      exactly one of the two is set (XOR). Existing rows (task set, child NULL)
      satisfy it, so the constraint validates against current data without a
      backfill.
    * Partial UNIQUE index on `(child_project_uuid) WHERE child_project_uuid IS
      NOT NULL` — a project is a child of at most one parent assignment. This is
      also what forces template cloning to *deep-clone* child subtrees rather
      than point two parents at the same child. It also serves the "find the
      linking row for this child" lookups (parent breadcrumb, rollup sync): an
      equality predicate `child_project_uuid = $1` implies `IS NOT NULL`, so
      Postgres uses the partial index for it — no separate plain index needed.

  Idempotent: re-running is a no-op once the column/constraints/indexes exist.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = schema_for(prefix)

    add_child_project_uuid_column(p, schema)
    add_child_project_uuid_fk(p, schema)
    drop_task_uuid_not_null(p)
    add_task_xor_child_check(p, schema)
    create_child_project_unique_index(p, schema)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '127'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_child_project_unique")

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_task_xor_child
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_child_project_uuid_fkey
    """)

    # Drop the sub-project linking rows first — they're exactly the rows that
    # would violate the NOT NULL we restore below. Target them directly by
    # `child_project_uuid IS NOT NULL` (the column still exists here, dropped
    # just after): that's precisely the V127-created set, without leaning on
    # the XOR check we dropped two statements ago. The child projects survive
    # as standalone projects, but note this also cascade-deletes any
    # `phoenix_kit_project_dependencies` edges touching these assignments
    # (FK `ON DELETE CASCADE`), so a sub-project's dependency wiring is lost —
    # rollback is feature-removal, not a reversible round-trip.
    execute(
      "DELETE FROM #{p}phoenix_kit_project_assignments WHERE child_project_uuid IS NOT NULL"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS child_project_uuid"
    )

    # Restore the pre-V127 NOT NULL on task_uuid. Safe now: the XOR check is
    # gone and the only rows that could have had a NULL task_uuid (the child
    # links) were just deleted, so every remaining row is a plain
    # template-backed assignment with task_uuid set.
    execute("ALTER TABLE #{p}phoenix_kit_project_assignments ALTER COLUMN task_uuid SET NOT NULL")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '126'")
  end

  defp add_child_project_uuid_column(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_project_assignments'
          AND column_name = 'child_project_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_assignments
          ADD COLUMN child_project_uuid UUID;
      END IF;
    END $$;
    """)
  end

  # FK to the embedded child project. `ON DELETE RESTRICT` keeps the parent's
  # task list honest: you can't delete a project that is still embedded as a
  # sub-project — the context tears the subtree down explicitly instead.
  # Postgres has no `ADD CONSTRAINT IF NOT EXISTS`, so guard on the name.
  defp add_child_project_uuid_fk(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_project_assignments'
          AND constraint_name = 'phoenix_kit_project_assignments_child_project_uuid_fkey'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_assignments
          ADD CONSTRAINT phoenix_kit_project_assignments_child_project_uuid_fkey
          FOREIGN KEY (child_project_uuid)
          REFERENCES #{p}phoenix_kit_projects(uuid)
          ON DELETE RESTRICT;
      END IF;
    END $$;
    """)
  end

  # A sub-project assignment has no task template, so task_uuid must be
  # nullable. `DROP NOT NULL` is itself idempotent (a no-op when already
  # nullable), so no existence guard is needed.
  defp drop_task_uuid_not_null(p) do
    execute(
      "ALTER TABLE #{p}phoenix_kit_project_assignments ALTER COLUMN task_uuid DROP NOT NULL"
    )
  end

  # Exactly one of task_uuid / child_project_uuid is set. `<>` is boolean XOR
  # in Postgres. Existing rows (task set, child NULL) already satisfy it.
  defp add_task_xor_child_check(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_project_assignments'
          AND constraint_name = 'phoenix_kit_project_assignments_task_xor_child'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_assignments
          ADD CONSTRAINT phoenix_kit_project_assignments_task_xor_child
          CHECK ((task_uuid IS NOT NULL) <> (child_project_uuid IS NOT NULL));
      END IF;
    END $$;
    """)
  end

  # A project can be embedded as a sub-project in at most one parent. Partial
  # so the common task-backed rows (child NULL) don't collide.
  defp create_child_project_unique_index(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_project_assignments'
          AND indexname = 'phoenix_kit_project_assignments_child_project_unique'
      ) THEN
        CREATE UNIQUE INDEX phoenix_kit_project_assignments_child_project_unique
          ON #{p}phoenix_kit_project_assignments (child_project_uuid)
          WHERE child_project_uuid IS NOT NULL;
      END IF;
    END $$;
    """)
  end

  defp schema_for("public"), do: "public"
  defp schema_for(prefix), do: prefix

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
