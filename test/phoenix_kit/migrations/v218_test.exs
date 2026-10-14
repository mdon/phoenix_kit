defmodule PhoenixKit.Migrations.Postgres.V218Test do
  @moduledoc """
  V218's sync requests-per-minute default, run as the real SQL: the default moves
  60 -> 600, a connection still at 60 is raised and any other value is kept, a re-run
  changes nothing, a rollback restores the default without lowering a row, and the
  same statements work in a named schema.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V218
  alias PhoenixKit.Test.Repo

  @scratch "pk_v218_scratch"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker(schema \\ "public") do
    [[marker]] = query("SELECT obj_description('#{schema}.phoenix_kit'::regclass)")
    marker
  end

  defp column(schema \\ "public") do
    query(
      """
      SELECT data_type, column_default, is_nullable FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = 'phoenix_kit_sync_connections'
        AND column_name = 'rate_limit_requests_per_minute'
      """,
      [schema]
    )
  end

  # `limit` nil inserts with the column default.
  defp insert(name, limit, schema \\ "public") do
    {columns, values} =
      if limit,
        do: {", rate_limit_requests_per_minute", ", #{limit}"},
        else: {"", ""}

    query("""
    INSERT INTO #{schema}.phoenix_kit_sync_connections
      (name, direction, site_url, inserted_at, updated_at#{columns})
    VALUES ('#{name}', 'sender', 'https://#{name}.example.com', now(), now()#{values})
    """)
  end

  defp limits(schema \\ "public") do
    query(
      "SELECT name, rate_limit_requests_per_minute FROM #{schema}.phoenix_kit_sync_connections"
    )
    |> Map.new(fn [name, limit] -> {name, limit} end)
  end

  test "the chain is at 218 or later, with an integer that defaults to 600" do
    assert String.to_integer(marker()) >= 218
    assert [["integer", "600", "NO"]] = column()
  end

  test "a connection still at the old default of 60 is raised to 600; 120 and 0 are kept" do
    run(V218.down_statements("public"))
    insert("defaulted", nil)
    insert("sixty", 60)
    insert("chosen", 120)
    insert("unlimited", 0)
    assert limits()["defaulted"] == 60

    run(V218.up_statements("public"))

    assert limits() == %{"defaulted" => 600, "sixty" => 600, "chosen" => 120, "unlimited" => 0}
    assert marker() == "218"
    assert [["integer", "600", "NO"]] = column()
  end

  test "running it again changes nothing" do
    insert("chosen", 120)
    insert("raised", 600)
    run(V218.up_statements("public"))
    run(V218.up_statements("public"))

    assert limits() == %{"chosen" => 120, "raised" => 600}
    assert [["integer", "600", "NO"]] = column()
  end

  test "rolls back to a default of 60 without lowering any row, and forward again" do
    run(V218.down_statements("public"))
    insert("sixty", 60)
    run(V218.up_statements("public"))
    assert limits()["sixty"] == 600

    run(V218.down_statements("public"))
    assert [["integer", "60", "NO"]] = column()
    assert marker() == "217"
    assert limits()["sixty"] == 600, "a down cannot tell a raised row from a chosen 600"

    insert("new", nil)
    assert limits()["new"] == 60

    run(V218.up_statements("public"))
    assert [["integer", "600", "NO"]] = column()
    assert marker() == "218"
  end

  test "works in a named schema and leaves public alone" do
    run(V218.down_statements("public"))
    insert("public_sixty", 60)

    run([
      "CREATE SCHEMA #{@scratch}",
      "CREATE TABLE #{@scratch}.phoenix_kit (id integer)",
      "CREATE TABLE #{@scratch}.phoenix_kit_sync_connections " <>
        "(LIKE public.phoenix_kit_sync_connections INCLUDING DEFAULTS)"
    ])

    insert("sixty", 60, @scratch)
    insert("chosen", 120, @scratch)

    run(V218.up_statements(@scratch))

    assert limits(@scratch) == %{"sixty" => 600, "chosen" => 120}
    assert [["integer", "600", "NO"]] = column(@scratch)
    assert marker(@scratch) == "218"

    assert limits()["public_sixty"] == 60
    assert [["integer", "60", "NO"]] = column()

    run(V218.down_statements(@scratch))
    assert [["integer", "60", "NO"]] = column(@scratch)
    assert marker(@scratch) == "217"
  end
end
