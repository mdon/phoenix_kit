defmodule PhoenixKit.Migrations.Postgres.V223Test do
  @moduledoc """
  V223's AI costs in dollars, run as the real SQL: `cost_cents` (integer, millionths)
  becomes `cost` (numeric(20,10), dollars) with every cost converted, an unreleased
  `cost_nanodollars` (billionths) likewise, the settings untouched, the spend indexes
  follow the rename, a re-run converts nothing twice, a rollback turns the costs back into
  millionths, and the same statements work in a named schema.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V223
  alias PhoenixKit.Test.Repo

  @scratch "pk_v223_scratch"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker(schema \\ "public") do
    [[marker]] = query("SELECT obj_description('#{schema}.phoenix_kit'::regclass)")
    marker
  end

  # [[column, type]] of the cost column, whichever name it has
  defp cost_column(schema \\ "public") do
    query(
      """
      SELECT column_name, format_type(atttypid, atttypmod)
      FROM information_schema.columns c
      JOIN pg_attribute a ON a.attname = c.column_name
        AND a.attrelid = (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass
      WHERE c.table_schema = $1 AND c.table_name = 'phoenix_kit_ai_requests'
        AND c.column_name IN ('cost', 'cost_cents', 'cost_nanodollars')
      """,
      [schema]
    )
  end

  defp spend_index_definitions(schema \\ "public") do
    query(
      """
      SELECT indexdef FROM pg_indexes
      WHERE schemaname = $1 AND indexname LIKE 'phoenix_kit_ai_requests_%_spend_idx'
      ORDER BY indexname
      """,
      [schema]
    )
    |> List.flatten()
  end

  defp insert_request(model, cost, column, schema \\ "public") do
    query(
      "INSERT INTO #{schema}.phoenix_kit_ai_requests (model, #{column}, inserted_at, updated_at) " <>
        "VALUES ($1, $2, now(), now())",
      [model, if(is_binary(cost), do: Decimal.new(cost), else: cost)]
    )
  end

  defp costs(column, schema \\ "public") do
    query("SELECT model, #{column} FROM #{schema}.phoenix_kit_ai_requests")
    |> Map.new(fn [model, cost] -> {model, cost} end)
  end

  defp put_setting(key, value, schema \\ "public") do
    query(
      "INSERT INTO #{schema}.phoenix_kit_settings (key, value, module) VALUES ($1, $2, 'ai') " <>
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [key, value]
    )
  end

  defp setting(key, schema \\ "public") do
    [[value]] = query("SELECT value FROM #{schema}.phoenix_kit_settings WHERE key = $1", [key])
    value
  end

  defp seed_caps(schema \\ "public") do
    put_setting("ai_daily_budget", "5000000", schema)
    put_setting("ai_daily_budget_per_endpoint", " 250000 ", schema)
    put_setting("ai_daily_budget_per_user", "0", schema)
    put_setting("ai_daily_calls_per_user", "200", schema)
  end

  defp dollars(map), do: Map.new(map, fn {k, v} -> {k, v && Decimal.new(v)} end)

  defp assert_costs(column, expected, schema \\ "public") do
    actual = costs(column, schema)
    assert Map.keys(actual) == Map.keys(expected)

    for {model, want} <- dollars(expected) do
      got = actual[model]

      assert (is_nil(want) and is_nil(got)) or Decimal.equal?(got, want),
             "#{model}: expected #{inspect(want)}, got #{inspect(got)}"
    end
  end

  defp to_nanodollars do
    run([
      "ALTER TABLE public.phoenix_kit_ai_requests ALTER COLUMN cost TYPE bigint " <>
        "USING round(cost * 1000000000)::bigint",
      "ALTER TABLE public.phoenix_kit_ai_requests RENAME COLUMN cost TO cost_nanodollars"
    ])
  end

  test "the chain is at 223 or later, with a numeric(20,10) cost in both spend indexes" do
    assert String.to_integer(marker()) >= 223
    assert [["cost", "numeric(20,10)"]] = cost_column()

    assert [endpoint_idx, user_idx] = spend_index_definitions()
    assert endpoint_idx =~ "(endpoint_uuid, inserted_at) INCLUDE (cost)"
    assert user_idx =~ "(user_uuid, inserted_at) INCLUDE (cost)"
  end

  test "millionths become dollars; the settings are left as they are" do
    run(V223.down_statements("public"))
    assert [["cost_cents", "integer"]] = cost_column()

    insert_request("embedding", 20, "cost_cents")
    insert_request("free", 0, "cost_cents")
    insert_request("unpriced", nil, "cost_cents")
    insert_request("expensive", 2_000_000_000, "cost_cents")
    seed_caps()

    run(V223.up_statements("public"))

    assert [["cost", "numeric(20,10)"]] = cost_column()
    assert marker() == "223"

    assert_costs("cost", %{
      "embedding" => "0.00002",
      "free" => "0",
      "unpriced" => nil,
      "expensive" => "2000"
    })

    assert setting("ai_daily_budget") == "5000000"
    assert setting("ai_daily_budget_per_endpoint") == " 250000 "
    assert setting("ai_daily_budget_per_user") == "0"
    assert setting("ai_daily_calls_per_user") == "200"
  end

  test "a database on the unreleased nanodollar V223 is converted too" do
    insert_request("embedding", "0.00000004", "cost")
    insert_request("chat", "1.5", "cost")
    to_nanodollars()
    assert [["cost_nanodollars", "bigint"]] = cost_column()
    assert costs("cost_nanodollars") == %{"embedding" => 40, "chat" => 1_500_000_000}

    run(V223.up_statements("public"))

    assert [["cost", "numeric(20,10)"]] = cost_column()
    assert_costs("cost", %{"embedding" => "0.00000004", "chat" => "1.5"})
    assert [endpoint_idx, _] = spend_index_definitions()
    assert endpoint_idx =~ "INCLUDE (cost)"
  end

  test "a table with cost and a legacy column stops the migration, up and down" do
    run(["ALTER TABLE public.phoenix_kit_ai_requests ADD COLUMN cost_cents integer"])

    assert_raise Postgrex.Error, ~r/has cost and a legacy cost column/, fn ->
      Repo.transaction(fn -> run(V223.up_statements("public")) end)
    end

    assert_raise Postgrex.Error, ~r/has both cost and cost_cents/, fn ->
      Repo.transaction(fn -> run(V223.down_statements("public")) end)
    end
  end

  test "a table with both legacy columns stops the migration" do
    run(V223.down_statements("public"))
    run(["ALTER TABLE public.phoenix_kit_ai_requests ADD COLUMN cost_nanodollars bigint"])

    assert_raise Postgrex.Error, ~r/has both cost_cents and cost_nanodollars/, fn ->
      Repo.transaction(fn -> run(V223.up_statements("public")) end)
    end
  end

  test "running it again converts nothing twice" do
    insert_request("embedding", "0.00002", "cost")

    run(V223.up_statements("public"))
    run(V223.up_statements("public"))

    assert_costs("cost", %{"embedding" => "0.00002"})
  end

  test "rolls back to integer cost_cents in millionths, and forward again" do
    insert_request("embedding", "0.0000204", "cost")
    insert_request("tiny", "0.00000016", "cost")
    put_setting("ai_daily_budget", "5000000")

    run(V223.down_statements("public"))

    assert [["cost_cents", "integer"]] = cost_column()
    assert marker() == "222"
    assert costs("cost_cents") == %{"embedding" => 20, "tiny" => 0}
    assert setting("ai_daily_budget") == "5000000"
    assert [endpoint_idx, _] = spend_index_definitions()
    assert endpoint_idx =~ "INCLUDE (cost_cents)"

    run(V223.down_statements("public"))
    assert costs("cost_cents") == %{"embedding" => 20, "tiny" => 0}

    run(V223.up_statements("public"))
    assert [["cost", "numeric(20,10)"]] = cost_column()
    assert_costs("cost", %{"embedding" => "0.00002", "tiny" => "0"})
  end

  test "a cost an integer of millionths cannot hold stops the rollback" do
    insert_request("huge", "2147.484", "cost")

    assert_raise Postgrex.Error, ~r/integer out of range/, fn ->
      Repo.transaction(fn -> run(V223.down_statements("public")) end)
    end
  end

  test "works in a named schema and leaves public alone" do
    run(V223.down_statements("public"))
    insert_request("public_row", 20, "cost_cents")
    put_setting("ai_daily_budget", "5000000")

    run([
      "CREATE SCHEMA #{@scratch}",
      "CREATE TABLE #{@scratch}.phoenix_kit (id integer)",
      "CREATE TABLE #{@scratch}.phoenix_kit_ai_requests " <>
        "(LIKE public.phoenix_kit_ai_requests INCLUDING DEFAULTS INCLUDING INDEXES)",
      "CREATE TABLE #{@scratch}.phoenix_kit_settings " <>
        "(LIKE public.phoenix_kit_settings INCLUDING DEFAULTS INCLUDING INDEXES)"
    ])

    insert_request("scratch_row", 7, "cost_cents", @scratch)
    seed_caps(@scratch)

    run(V223.up_statements(@scratch))

    assert [["cost", "numeric(20,10)"]] = cost_column(@scratch)
    assert_costs("cost", %{"scratch_row" => "0.000007"}, @scratch)
    assert setting("ai_daily_budget", @scratch) == "5000000"
    assert marker(@scratch) == "223"

    assert [["cost_cents", "integer"]] = cost_column()
    assert costs("cost_cents") == %{"public_row" => 20}

    run(V223.down_statements(@scratch))
    assert [["cost_cents", "integer"]] = cost_column(@scratch)
    assert costs("cost_cents", @scratch) == %{"scratch_row" => 7}
    assert marker(@scratch) == "222"
  end
end
