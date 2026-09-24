defmodule PhoenixKit.Migrations.Adoption do
  @moduledoc """
  Public, documented API for module-owned migration chains that adopt a
  core-baseline table (`dev_docs/guides/2026-09-05-module-table-extraction-guide.md`)
  to verify its shape before claiming ownership — not just its presence.

  ## The bug this exists to let module authors close

  A module chain adopts a core table with `CREATE TABLE IF NOT EXISTS` /
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, then stamps ownership with
  `COMMENT ON TABLE ... IS '<marker_prefix><N>'`. `IF NOT EXISTS` checks
  *existence*, never *shape*: a column narrowed by hand outside migrations
  (say, a money column quietly changed from `numeric(15,2)` to
  `numeric(10,2)` by an operator working straight against the database)
  survives adoption completely silently — exit 0, marker written, the
  narrower type never noticed. This module closes that gap by giving a
  module's adoption step a way to assert "the table I am about to claim
  actually has the shape I expect" before it writes the marker.

  This module is a thin, **stability-committed** facade over
  `PhoenixKit.Migrations.Repair.Differ` and `PhoenixKit.Migrations.Repair.Probe`
  (core's existing structural-diff engine for `mix phoenix_kit.repair`) —
  unlike those two, which carry no external-API stability claim, this
  module's public functions are safe for a module package to depend on
  across core releases.

  ## `verify_shape/3` — the vocabulary

  `checks` is a flat list of per-object shape declarations, in the exact
  same `class`/`check`/`expected`-shape vocabulary
  `PhoenixKit.Migrations.ExpectedSchema` already uses internally for its
  own manifest entries (see `PhoenixKit.Migrations.ExpectedSchema.Object`'s
  moduledoc, "Per-class shape keys") — so a module author copies a
  familiar shape, not a novel one. A `:column` check, matching a real
  manifest entry's fields exactly:

      %{
        class: :column,
        check: {:catalog, %{kind: :column, table: "phoenix_kit_subscription_types", column: "price"}},
        expected: %{type: "numeric(15,2)", not_null: true, default: nil}
      }

  An `:index` check:

      %{
        class: :index,
        check: {:catalog, %{kind: :index, name: "phoenix_kit_currencies_default_uidx"}},
        expected: %{unique: true, method: "btree", keys: ["is_default"], opclasses: ["bool_ops"], predicate: "is_default"}
      }

  A `:constraint` check (primary key):

      %{
        class: :constraint,
        check: {:catalog, %{kind: :constraint, table: "phoenix_kit_orders", name: "phoenix_kit_orders_pkey"}},
        expected: %{type: "p", columns: ["uuid"]}
      }

  Only the fields `PhoenixKit.Migrations.Repair.Differ.compare/3` actually
  reads for that `class` need to be present in `expected` — see its
  moduledoc for the exact field list per class (columns: `type`,
  `not_null`, `default`; indexes: `unique`, `method`, `keys`, `opclasses`,
  `predicate`; constraints: dispatched on `expected.type`, see `Differ`).

  `verify_shape/3` takes one `Probe.snapshot/2` of the target server, then
  runs every check against it and collects **every** drifted object in one
  pass — it never stops at the first mismatch, so a caller sees the full
  diff at once. An object the caller expects but that is entirely absent
  (dropped by a stray manual `DROP INDEX`, say) is reported as drift too,
  with its own `"missing: ..."` reason — this is deliberately not the same
  question `mix phoenix_kit.repair` answers (whether to *create* it); it is
  purely "does reality match what I declared".

  ## The recommended pattern: verify, then decline-and-raise on drift

  `verify_shape/3` and `marker_conflict/4` themselves never raise and never
  touch the database — they only report. The **recommended** pattern for a
  module's adoption step, demonstrated here and not duplicated elsewhere in
  this guide, is: run the additive `CREATE TABLE IF NOT EXISTS` /
  `ADD COLUMN IF NOT EXISTS` statements first (as today), then verify shape,
  then check for a marker conflict, and only if BOTH pass, write the
  ownership marker. On drift, **decline the marker and raise** with the
  diff rendered into the message — never silently skip, and never
  auto-repair:

      defmodule MyModule.Migrations do
        alias PhoenixKit.Migrations.Adoption

        @marker_prefix "mym_schema:"

        def up(repo, prefix) do
          p = "\#{prefix}."

          repo.query!(\"\"\"
          CREATE TABLE IF NOT EXISTS \#{p}phoenix_kit_subscription_types (
            "uuid" uuid PRIMARY KEY DEFAULT \#{p}uuid_generate_v7(),
            "price" numeric(15,2) NOT NULL
          )
          \"\"\")

          checks = [
            %{
              class: :column,
              check: {:catalog, %{kind: :column, table: "phoenix_kit_subscription_types", column: "price"}},
              expected: %{type: "numeric(15,2)", not_null: true, default: nil}
            }
          ]

          case Adoption.verify_shape(repo, prefix, checks) do
            :ok ->
              :ok

            {:drift, diffs} ->
              raise \"\"\"
              MyModule cannot adopt phoenix_kit_subscription_types: its shape on \
              this database does not match what MyModule expects.

              \#{format_diffs(diffs)}

              Fix the table's shape to match, or adjust MyModule's expectation, \
              then re-run this migration.
              \"\"\"
          end

          case Adoption.marker_conflict(repo, prefix, "phoenix_kit_subscription_types", @marker_prefix) do
            :ok ->
              repo.query!(
                "COMMENT ON TABLE \#{p}phoenix_kit_subscription_types IS '\#{@marker_prefix}1'"
              )

            {:conflict, existing} ->
              raise "MyModule cannot adopt phoenix_kit_subscription_types: " <>
                      "it already carries an unrelated marker (\#{inspect(existing)})"
          end
        end

        defp format_diffs(diffs) do
          Enum.map_join(diffs, "\\n", fn %{check: check, reasons: reasons} ->
            "  \#{inspect(check)}: \#{Enum.join(reasons, "; ")}"
          end)
        end
      end

  ### Why decline-and-raise, not auto-fix

  Auto-fixing DDL during unattended adoption (at app boot, with no operator
  watching) carries the same silent-mutation risk this module exists to
  close, just inverted — a column silently widened back is a smaller but
  structurally identical mistake to a column silently narrowed: the host's
  schema changes without anyone being told. Automatic repair already
  exists, deliberately operator-invoked: `mix phoenix_kit.repair`. Keeping
  adoption's shape check detection-only, and leaving repair as the one tool
  that ever issues corrective DDL, keeps each doing the one job it is
  suited for — detection is safe to run unattended, DDL mutation is not.
  An unhandled `raise` during a migration halts the chain (the version
  marker is never advanced), so the host does not boot into a
  half-adopted state and the operator sees exactly what disagreed.

  ## `marker_conflict/4`

  Reads the current `COMMENT ON TABLE` for an arbitrary, caller-given
  table (not core's own `phoenix_kit` meta table — this is a new,
  parameterized query, schema-anchored the same way
  `PhoenixKit.Migrations.Repair.Probe.raw_comment/2` anchors its read of
  core's own marker). `:ok` when the comment is absent, `nil`, or already
  starts with the caller's own `own_marker_prefix` (an ordinary version
  bump by the SAME module); `{:conflict, existing_comment}` for anything
  else — another module's marker, or an operator's own hand-written
  documentation comment on the table — so the caller can decline to
  overwrite it rather than silently stomping it.

  `own_marker_prefix` must include the same trailing separator the
  caller's own marker-write statement uses (the existing convention across
  `phoenix_kit_billing`/`phoenix_kit_legal` is a trailing colon, e.g.
  `"pkb_schema:"`) — a prefix without it risks a false match against an
  unrelated but similarly-named module (`"pkb_schema"` would also match a
  hypothetical `"pkb_schema_v2:1"`).
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe

  @typedoc """
  One object's declared expectation: `class` picks the
  `PhoenixKit.Migrations.Repair.Differ.compare/3` clause, `check` locates
  the observed object in a `Probe.snapshot/2` result (same shape
  `PhoenixKit.Migrations.ExpectedSchema.Object.check/0` uses), `expected`
  is the per-class shape map `Differ.compare/3` reads fields out of — see
  the moduledoc for concrete examples per class.
  """
  @type shape_check :: %{
          class: Object.class(),
          check: Object.check(),
          expected: map()
        }

  @typedoc "One drifted object: the check that found it, and every disagreeing field's reason."
  @type drift :: %{check: Object.check(), reasons: [String.t()]}

  @doc """
  Verifies every declared `checks` entry against the real, current shape
  of `prefix` on `repo` — one `Probe.snapshot/2` round trip, then a
  `Differ.compare/3` per check. Returns `:ok` when every object matches;
  `{:drift, diffs}` (never stopping at the first mismatch) otherwise, one
  `t:drift/0` entry per object that disagreed OR was entirely missing.

  Never raises on drift and never executes DDL — purely a read. See the
  moduledoc's "recommended pattern" for how a caller is expected to react
  to `{:drift, diffs}`.
  """
  @spec verify_shape(Ecto.Repo.t(), String.t(), [shape_check()]) ::
          :ok | {:drift, [drift()]}
  def verify_shape(repo, prefix, checks) when is_list(checks) do
    Helpers.validate_prefix!(prefix)
    snapshot = Probe.snapshot(repo, prefix)

    drifted =
      checks
      |> Enum.map(&compare_check(&1, snapshot))
      |> Enum.reject(&is_nil/1)

    if drifted == [], do: :ok, else: {:drift, drifted}
  end

  # `Differ.compare/3` assumes both shapes are already non-nil (its own
  # moduledoc: "never looks at :missing ... that is a presence question the
  # caller answers before ever calling here") — `Probe.lookup/2` returning
  # `nil` (the object is not on the target server at all) is therefore
  # handled here, as its own drift reason, and never reaches `compare/3`.
  defp compare_check(%{class: class, check: check, expected: expected}, snapshot) do
    case Probe.lookup(snapshot, check) do
      nil ->
        %{check: check, reasons: ["missing: no #{class} matching #{inspect(check)} found"]}

      observed ->
        case Differ.compare(class, expected, observed) do
          :match -> nil
          {:mismatch, reasons} -> %{check: check, reasons: reasons}
        end
    end
  end

  @doc """
  Reads the current `COMMENT ON TABLE` on `table` (schema-anchored to
  `prefix`) and decides whether the caller may write its own marker there.

  `:ok` when the table has no comment, or its comment already starts with
  `own_marker_prefix`; `{:conflict, existing_comment}` otherwise. Never
  writes anything — the caller decides what to do with a conflict (the
  recommended pattern, per the moduledoc, is to decline and raise).
  """
  @spec marker_conflict(Ecto.Repo.t(), String.t(), String.t(), String.t()) ::
          :ok | {:conflict, String.t()}
  def marker_conflict(repo, prefix, table, own_marker_prefix)
      when is_binary(table) and table != "" and is_binary(own_marker_prefix) do
    Helpers.validate_prefix!(prefix)

    case raw_table_comment(repo, prefix, table) do
      :absent ->
        :ok

      nil ->
        :ok

      comment ->
        if String.starts_with?(comment, own_marker_prefix), do: :ok, else: {:conflict, comment}
    end
  end

  # Mirrors PhoenixKit.Migrations.Repair.Probe.raw_comment/2's own two-query
  # shape (table-exists, schema-anchored; then obj_description via the
  # pg_class/pg_namespace join) — that function is hardcoded to the
  # `phoenix_kit` meta table specifically, so this is a small reusable
  # version parameterized on an arbitrary caller-given table, fully
  # bind-parameterized rather than interpolated.
  defp raw_table_comment(repo, prefix, table) do
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1
      AND table_schema = $2
    )
    """

    case repo.query(table_exists_query, [table, prefix], log: false) do
      {:ok, %{rows: [[true]]}} -> read_table_comment(repo, prefix, table)
      _ -> :absent
    end
  end

  defp read_table_comment(repo, prefix, table) do
    comment_query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = $1
    AND pg_namespace.nspname = $2
    """

    case repo.query(comment_query, [table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      _ -> nil
    end
  end
end
