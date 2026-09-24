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

  @prefix "public"

  defp unique_table(base), do: "#{base}_#{System.unique_integer([:positive])}"

  defp drop_on_exit(table) do
    on_exit(fn -> Repo.query("DROP TABLE IF EXISTS #{table}", []) end)
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
  end
end
