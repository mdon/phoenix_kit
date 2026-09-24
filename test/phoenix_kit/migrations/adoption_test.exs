defmodule PhoenixKit.Migrations.AdoptionTest do
  @moduledoc """
  Real-DB coverage for `PhoenixKit.Migrations.Adoption` — the structural
  shape-verification wrapper a module's adoption step calls before writing
  its ownership marker. Every test builds its own throwaway table (never a
  real PhoenixKit-owned one) directly under the default `public` prefix;
  `PhoenixKit.DataCase`'s per-test sandbox transaction rolls each one back,
  the same isolation `test/integration/v168_slug_index_test.exs` relies on
  for its own scratch tables — the `on_exit` drops below are defensive,
  not load-bearing.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Adoption
  alias PhoenixKit.Migrations.Repair.Differ

  @prefix "public"

  defp unique_table(base), do: "#{base}_#{System.unique_integer([:positive])}"

  defp drop_on_exit(table) do
    on_exit(fn -> Repo.query("DROP TABLE IF EXISTS #{table}", []) end)
  end

  # Bounded to fit Helpers.validate_prefix!/1's 20-byte cap (see
  # prefix_migration_test.exs's @schema for the same constraint) — a bare
  # unique_table/1-style suffix easily runs past it.
  defp unique_schema(base) do
    suffix = System.unique_integer([:positive]) |> rem(100_000)
    "#{base}#{suffix}"
  end

  describe "verify_shape/3 — column drift (money column narrowing)" do
    setup do
      table = unique_table("pk_adoption_test_money")
      drop_on_exit(table)

      Repo.query!("""
      CREATE TABLE #{table} (
        id serial PRIMARY KEY,
        amount numeric(15,2) NOT NULL
      )
      """)

      Repo.query!("INSERT INTO #{table} (amount) VALUES (12345.67), (89.01)")

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "amount"}},
          expected: %{type: "numeric(15,2)", not_null: true, default: nil}
        }
      ]

      {:ok, table: table, checks: checks}
    end

    test "canonical (unnarrowed) shape verifies clean", %{table: table, checks: checks} do
      assert Adoption.verify_shape(Repo, @prefix, checks) == :ok

      %{rows: rows} = Repo.query!("SELECT amount FROM #{table} ORDER BY amount")
      assert rows == [[Decimal.new("89.01")], [Decimal.new("12345.67")]]
    end

    test "a column narrowed out-of-band is reported as drift, with an exact diff, and existing data is untouched",
         %{table: table, checks: checks} do
      # Simulates the out-of-band narrowing the issue describes: an operator
      # runs this ALTER by hand, outside any migration. Both existing values
      # fit numeric(10,2), so Postgres allows the ALTER itself to succeed —
      # confirming the mechanism has to catch this via a later shape check,
      # not rely on the narrowing itself failing.
      Repo.query!("ALTER TABLE #{table} ALTER COLUMN amount TYPE numeric(10,2)")

      assert {:drift, [%{check: check, reasons: reasons}]} =
               Adoption.verify_shape(Repo, @prefix, checks)

      assert check == {:catalog, %{kind: :column, table: table, column: "amount"}}
      assert Enum.any?(reasons, &String.starts_with?(&1, "type:"))
      assert Enum.any?(reasons, &(&1 =~ "numeric(15,2)"))
      assert Enum.any?(reasons, &(&1 =~ "numeric(10,2)"))

      # verify_shape/3 never executes DDL — the mechanism itself never
      # touches data. Trivially true here, asserted anyway per the issue's
      # explicit "no data loss" requirement.
      %{rows: rows} = Repo.query!("SELECT amount FROM #{table} ORDER BY amount")
      assert rows == [[Decimal.new("89.01")], [Decimal.new("12345.67")]]
    end

    test "running verify_shape/3 twice against the same narrowed table gives identical results",
         %{table: table, checks: checks} do
      Repo.query!("ALTER TABLE #{table} ALTER COLUMN amount TYPE numeric(10,2)")

      result1 = Adoption.verify_shape(Repo, @prefix, checks)
      result2 = Adoption.verify_shape(Repo, @prefix, checks)

      assert {:drift, _} = result1
      assert result1 == result2
    end
  end

  describe "verify_shape/3 — missing object" do
    test "a column dropped out-of-band is reported as drift, not silently ignored or crashed on" do
      table = unique_table("pk_adoption_test_missing_column")
      drop_on_exit(table)

      Repo.query!("""
      CREATE TABLE #{table} (
        id serial PRIMARY KEY,
        legacy_flag boolean NOT NULL DEFAULT false
      )
      """)

      Repo.query!("ALTER TABLE #{table} DROP COLUMN legacy_flag")

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "legacy_flag"}},
          expected: %{type: "boolean", not_null: true, default: "false"}
        }
      ]

      assert {:drift, [%{check: check, reasons: reasons}]} =
               Adoption.verify_shape(Repo, @prefix, checks)

      assert check == {:catalog, %{kind: :column, table: table, column: "legacy_flag"}}
      assert Enum.any?(reasons, &String.starts_with?(&1, "missing:"))
    end

    test "an index dropped out-of-band is reported as drift" do
      table = unique_table("pk_adoption_test_missing_index")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (slug text NOT NULL)")
      Repo.query!("CREATE UNIQUE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")
      Repo.query!("DROP INDEX #{table}_slug_uidx")

      checks = [
        %{
          class: :index,
          check: {:catalog, %{kind: :index, name: "#{table}_slug_uidx"}},
          expected: %{
            unique: true,
            method: "btree",
            keys: ["slug"],
            opclasses: ["text_ops"],
            predicate: nil
          }
        }
      ]

      assert {:drift, [%{check: check, reasons: reasons}]} =
               Adoption.verify_shape(Repo, @prefix, checks)

      assert check == {:catalog, %{kind: :index, name: "#{table}_slug_uidx"}}
      assert Enum.any?(reasons, &String.starts_with?(&1, "missing:"))
    end
  end

  describe "verify_shape/3 — index shape" do
    test "a unique index matching the expected shape verifies clean" do
      table = unique_table("pk_adoption_test_index_ok")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (slug text NOT NULL)")
      Repo.query!("CREATE UNIQUE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")

      checks = [
        %{
          class: :index,
          check: {:catalog, %{kind: :index, name: "#{table}_slug_uidx"}},
          expected: %{
            unique: true,
            method: "btree",
            keys: ["slug"],
            opclasses: ["text_ops"],
            predicate: nil
          }
        }
      ]

      assert Adoption.verify_shape(Repo, @prefix, checks) == :ok
    end

    test "an index narrowed from unique to non-unique out-of-band is reported as drift" do
      table = unique_table("pk_adoption_test_index_narrowed")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (slug text NOT NULL)")
      Repo.query!("CREATE UNIQUE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")

      # Simulates an operator dropping and recreating the index without the
      # UNIQUE keyword, outside any migration.
      Repo.query!("DROP INDEX #{table}_slug_uidx")
      Repo.query!("CREATE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")

      checks = [
        %{
          class: :index,
          check: {:catalog, %{kind: :index, name: "#{table}_slug_uidx"}},
          expected: %{
            unique: true,
            method: "btree",
            keys: ["slug"],
            opclasses: ["text_ops"],
            predicate: nil
          }
        }
      ]

      assert {:drift, [%{reasons: reasons}]} = Adoption.verify_shape(Repo, @prefix, checks)
      assert Enum.any?(reasons, &String.starts_with?(&1, "unique:"))
    end
  end

  describe "verify_shape/3 — constraint shape" do
    test "a composite primary key matching the expected shape verifies clean" do
      table = unique_table("pk_adoption_test_pk_ok")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (a int NOT NULL, b int NOT NULL, c int NOT NULL)")
      Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (a, b)")

      checks = [
        %{
          class: :constraint,
          check: {:catalog, %{kind: :constraint, table: table, name: "#{table}_pkey"}},
          expected: %{type: "p", columns: ["a", "b"]}
        }
      ]

      assert Adoption.verify_shape(Repo, @prefix, checks) == :ok
    end

    test "a primary key narrowed from two columns to one out-of-band is reported as drift" do
      table = unique_table("pk_adoption_test_pk_narrowed")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (a int NOT NULL, b int NOT NULL, c int NOT NULL)")
      Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (a, b)")

      # Simulates an operator dropping and recreating the constraint with
      # fewer columns, outside any migration.
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{table}_pkey")
      Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (a)")

      checks = [
        %{
          class: :constraint,
          check: {:catalog, %{kind: :constraint, table: table, name: "#{table}_pkey"}},
          expected: %{type: "p", columns: ["a", "b"]}
        }
      ]

      assert {:drift, [%{reasons: reasons}]} = Adoption.verify_shape(Repo, @prefix, checks)
      assert Enum.any?(reasons, &String.starts_with?(&1, "columns:"))
    end
  end

  describe "marker_conflict/4" do
    setup do
      table = unique_table("pk_adoption_test_marker")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (id serial PRIMARY KEY)")

      {:ok, table: table}
    end

    test "a table with no comment at all is :ok", %{table: table} do
      assert Adoption.marker_conflict(Repo, @prefix, table, "myns_schema:") == :ok
    end

    test "a table already carrying the caller's own marker prefix is :ok (a normal version bump)",
         %{table: table} do
      Repo.query!(~s(COMMENT ON TABLE #{table} IS 'myns_schema:1'))

      assert Adoption.marker_conflict(Repo, @prefix, table, "myns_schema:") == :ok
    end

    test "a table carrying a DIFFERENT module's marker declines with {:conflict, existing}", %{
      table: table
    } do
      Repo.query!(~s(COMMENT ON TABLE #{table} IS 'otherns_schema:3'))

      assert Adoption.marker_conflict(Repo, @prefix, table, "myns_schema:") ==
               {:conflict, "otherns_schema:3"}
    end

    test "a table carrying an operator's own hand-written comment declines with {:conflict, existing}",
         %{table: table} do
      Repo.query!(~s(COMMENT ON TABLE #{table} IS 'do not touch, legacy billing export'))

      assert Adoption.marker_conflict(Repo, @prefix, table, "myns_schema:") ==
               {:conflict, "do not touch, legacy billing export"}
    end

    test "an empty own_marker_prefix raises rather than silently matching every comment (MINOR 9)",
         %{table: table} do
      Repo.query!(~s(COMMENT ON TABLE #{table} IS 'do not touch, legacy billing export'))

      assert_raise FunctionClauseError, fn ->
        Adoption.marker_conflict(Repo, @prefix, table, "")
      end
    end

    test "a table that does not exist at all is :ok, not an error (MINOR 9 regression)" do
      assert Adoption.marker_conflict(
               Repo,
               @prefix,
               "pk_adoption_test_table_does_not_exist_at_all",
               "myns_schema:"
             ) == :ok
    end
  end

  describe "marker_conflict/5 — core's own pre-squash legacy comments (MAJOR 2)" do
    # `@core_legacy_table_comments` is keyed by real core table names
    # (`phoenix_kit_currencies`, etc.), which already exist under `public`
    # in a fully-migrated test database — so this exercises the match
    # inside a scratch, non-`public` schema instead of colliding with (or
    # having to drop) the real table. This doubles as MINOR 11's
    # non-`public`-prefix coverage.
    setup do
      schema = unique_schema("pkadlg")
      Repo.query!("CREATE SCHEMA #{schema}")
      on_exit(fn -> Repo.query("DROP SCHEMA IF EXISTS #{schema} CASCADE", []) end)

      Repo.query!("CREATE TABLE #{schema}.phoenix_kit_currencies (id serial PRIMARY KEY)")

      {:ok, schema: schema}
    end

    test "a table carrying core's exact known pre-squash legacy comment is :ok", %{
      schema: schema
    } do
      Repo.query!(
        ~s(COMMENT ON TABLE #{schema}.phoenix_kit_currencies IS 'Supported currencies for billing with exchange rates')
      )

      assert Adoption.marker_conflict(Repo, schema, "phoenix_kit_currencies", "pkb_schema:") ==
               :ok
    end

    test "a DIFFERENT, non-listed comment on the same table still declines (regression: not overly permissive)",
         %{schema: schema} do
      Repo.query!(
        ~s(COMMENT ON TABLE #{schema}.phoenix_kit_currencies IS 'some unrelated hand-written comment')
      )

      assert Adoption.marker_conflict(Repo, schema, "phoenix_kit_currencies", "pkb_schema:") ==
               {:conflict, "some unrelated hand-written comment"}
    end

    test "a caller-supplied :overwritable comment is :ok", %{schema: schema} do
      Repo.query!(
        ~s(COMMENT ON TABLE #{schema}.phoenix_kit_currencies IS 'caller-known-safe legacy text')
      )

      assert Adoption.marker_conflict(Repo, schema, "phoenix_kit_currencies", "pkb_schema:",
               overwritable: ["caller-known-safe legacy text"]
             ) == :ok
    end
  end

  describe "verify_shape/3 — not_null drift Differ itself skips for repair's sake (MAJOR 1)" do
    setup do
      table = unique_table("pk_adoption_test_notnull_gap")
      drop_on_exit(table)

      Repo.query!("""
      CREATE TABLE #{table} (
        id serial PRIMARY KEY,
        amount numeric(15,2) NOT NULL
      )
      """)

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "amount"}},
          expected: %{type: "numeric(15,2)", not_null: true, default: nil}
        }
      ]

      {:ok, table: table, checks: checks}
    end

    test "a canonical NOT NULL column still verifies clean", %{checks: checks} do
      assert Adoption.verify_shape(Repo, @prefix, checks) == :ok
    end

    test "a column dropped to nullable out-of-band is reported as drift, not silently accepted",
         %{table: table, checks: checks} do
      Repo.query!("ALTER TABLE #{table} ALTER COLUMN amount DROP NOT NULL")

      assert {:drift, [%{check: check, reasons: reasons}]} =
               Adoption.verify_shape(Repo, @prefix, checks)

      assert check == {:catalog, %{kind: :column, table: table, column: "amount"}}
      assert Enum.any?(reasons, &String.starts_with?(&1, "not_null:"))
    end
  end

  describe "verify_shape/3 — malformed checks entries never raise (MINOR 7)" do
    test "an expected map missing a field its class needs is reported as drift, not raised" do
      table = unique_table("pk_adoption_test_incomplete_expected")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (id serial PRIMARY KEY, amount numeric(15,2) NOT NULL)")

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "amount"}},
          # missing :type, which Differ.compare/3's :column clause needs —
          # would raise KeyError from inside Differ without validation.
          expected: %{not_null: true, default: nil}
        }
      ]

      assert {:drift, [%{reasons: reasons}]} = Adoption.verify_shape(Repo, @prefix, checks)
      assert Enum.any?(reasons, &(&1 =~ "invalid check"))
    end

    test "an unrecognized class atom is reported as drift, not raised" do
      table = unique_table("pk_adoption_test_bogus_class")
      drop_on_exit(table)

      Repo.query!("CREATE TABLE #{table} (id serial PRIMARY KEY)")

      checks = [
        %{
          # no Differ.compare/3 clause matches :bogus — would raise
          # FunctionClauseError from inside Differ without validation.
          class: :bogus,
          check: {:catalog, %{kind: :table, name: table}},
          expected: %{}
        }
      ]

      assert {:drift, [%{reasons: reasons}]} = Adoption.verify_shape(Repo, @prefix, checks)
      assert Enum.any?(reasons, &(&1 =~ "invalid check"))
    end
  end

  describe "verify_shape/3 — two independent drifts in one call (regression: must not truncate)" do
    test "both a narrowed column and a narrowed index appear in the same {:drift, diffs} result" do
      table = unique_table("pk_adoption_test_double_drift")
      drop_on_exit(table)

      Repo.query!("""
      CREATE TABLE #{table} (
        id serial PRIMARY KEY,
        amount numeric(15,2) NOT NULL,
        slug text NOT NULL
      )
      """)

      Repo.query!("CREATE UNIQUE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")

      Repo.query!("ALTER TABLE #{table} ALTER COLUMN amount TYPE numeric(10,2)")
      Repo.query!("DROP INDEX #{table}_slug_uidx")
      Repo.query!("CREATE INDEX #{table}_slug_uidx ON #{table} USING btree (slug)")

      column_check = {:catalog, %{kind: :column, table: table, column: "amount"}}
      index_check = {:catalog, %{kind: :index, name: "#{table}_slug_uidx"}}

      checks = [
        %{
          class: :column,
          check: column_check,
          expected: %{type: "numeric(15,2)", not_null: true, default: nil}
        },
        %{
          class: :index,
          check: index_check,
          expected: %{
            unique: true,
            method: "btree",
            keys: ["slug"],
            opclasses: ["text_ops"],
            predicate: nil
          }
        }
      ]

      assert {:drift, diffs} = Adoption.verify_shape(Repo, @prefix, checks)
      assert length(diffs) == 2

      found_checks = Enum.map(diffs, & &1.check)
      assert column_check in found_checks
      assert index_check in found_checks
    end
  end

  describe "verify_shape/3 and marker_conflict/4 — non-public prefix (MINOR 11)" do
    test "both work the same way against a scratch, non-public schema" do
      schema = unique_schema("pkadopt")
      Repo.query!("CREATE SCHEMA #{schema}")
      on_exit(fn -> Repo.query("DROP SCHEMA IF EXISTS #{schema} CASCADE", []) end)

      table = "pk_adoption_test_prefixed"

      Repo.query!("""
      CREATE TABLE #{schema}.#{table} (
        id serial PRIMARY KEY,
        amount numeric(15,2) NOT NULL
      )
      """)

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "amount"}},
          expected: %{type: "numeric(15,2)", not_null: true, default: nil}
        }
      ]

      assert Adoption.verify_shape(Repo, schema, checks) == :ok
      assert Adoption.marker_conflict(Repo, schema, table, "myns_schema:") == :ok

      Repo.query!("ALTER TABLE #{schema}.#{table} ALTER COLUMN amount TYPE numeric(10,2)")
      assert {:drift, [%{reasons: reasons}]} = Adoption.verify_shape(Repo, schema, checks)
      assert Enum.any?(reasons, &String.starts_with?(&1, "type:"))
    end
  end

  describe "the full recommended pattern, end-to-end (MINOR 11)" do
    test "verify -> write marker on a clean shape; verify -> drift -> marker not written; idempotent" do
      table = unique_table("pk_adoption_test_e2e")
      drop_on_exit(table)

      Repo.query!("""
      CREATE TABLE #{table} (
        id serial PRIMARY KEY,
        amount numeric(15,2) NOT NULL
      )
      """)

      checks = [
        %{
          class: :column,
          check: {:catalog, %{kind: :column, table: table, column: "amount"}},
          expected: %{type: "numeric(15,2)", not_null: true, default: nil}
        }
      ]

      marker_prefix = "e2e_schema:"

      run_adoption_step = fn ->
        case Adoption.verify_shape(Repo, @prefix, checks) do
          :ok ->
            case Adoption.marker_conflict(Repo, @prefix, table, marker_prefix) do
              :ok ->
                Repo.query!(~s(COMMENT ON TABLE #{table} IS '#{marker_prefix}1'))
                :written

              {:conflict, existing} ->
                {:conflict, existing}
            end

          {:drift, diffs} ->
            {:drift, diffs}
        end
      end

      read_comment = fn ->
        %{rows: [[comment]]} =
          Repo.query!("SELECT obj_description('#{table}'::regclass, 'pg_class')")

        comment
      end

      # Clean shape: verify passes, no conflict, marker gets written.
      assert run_adoption_step.() == :written
      assert read_comment.() == "#{marker_prefix}1"

      # Running the whole sequence again is idempotent: the marker already
      # carries this module's own prefix, so marker_conflict/4 still says
      # :ok and the marker is rewritten to the same value.
      assert run_adoption_step.() == :written
      assert read_comment.() == "#{marker_prefix}1"

      # Narrow the column out-of-band: verify must now report drift, and
      # the marker must NOT be touched — it stays at its last-written value.
      Repo.query!("ALTER TABLE #{table} ALTER COLUMN amount TYPE numeric(10,2)")
      assert {:drift, _diffs} = run_adoption_step.()
      assert read_comment.() == "#{marker_prefix}1"
    end
  end

  describe "format_drift/1" do
    test "renders check + reasons and strips the deparse marker for display" do
      marker = Differ.deparse_text_marker()

      diffs = [
        %{
          check: {:catalog, %{kind: :column, table: "t", column: "c"}},
          reasons: [~s(type: expected "a", got "b")]
        },
        %{
          check: {:catalog, %{kind: :index, name: "i"}},
          reasons: [marker <> ~s(predicate: expected nil, got "x")]
        }
      ]

      rendered = Adoption.format_drift(diffs)

      assert rendered =~ ~s(type: expected "a", got "b")
      assert rendered =~ ~s(predicate: expected nil, got "x")
      refute rendered =~ marker
    end
  end
end
