defmodule PhoenixKit.Migrations.Postgres.V200Test do
  @moduledoc """
  V200's capture-date columns and index on `phoenix_kit_files`, run as the
  real SQL: down removes them, up puts them back (re-runnable), and each
  direction stamps its marker.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V200
  alias PhoenixKit.Test.Repo

  @columns [
    ["taken_at", "timestamp with time zone", "YES"],
    ["taken_at_offset", "integer", "YES"],
    ["taken_at_source", "character varying", "YES"],
    ["taken_on", "date", "YES"]
  ]

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
        AND column_name LIKE 'taken_%'
      ORDER BY column_name
      """)

    rows
  end

  defp index_definition do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'phoenix_kit_files_capture_date_index'
      """)

    List.flatten(rows)
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  test "down removes the columns and the index, up restores them, each stamps its marker" do
    run(V200.down_statements("public"))
    assert columns() == []
    assert index_definition() == []
    assert marker() == "199"

    run(V200.up_statements("public"))
    assert columns() == @columns
    assert [definition] = index_definition()
    assert definition =~ "(user_uuid, taken_on DESC, taken_at DESC)"
    assert definition =~ "system_managed = false"
    assert marker() == "200"
  end

  test "up is re-runnable" do
    run(V200.up_statements("public"))
    run(V200.up_statements("public"))

    assert columns() == @columns
    assert [_definition] = index_definition()
    assert marker() == "200"
  end
end
