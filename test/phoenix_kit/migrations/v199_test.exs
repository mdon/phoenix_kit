defmodule PhoenixKit.Migrations.Postgres.V199Test do
  @moduledoc """
  V199's `data` column on `phoenix_kit_files`, run as the real SQL: down
  removes it, up puts it back (re-runnable), and each direction stamps its
  marker.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V199
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp column_shape do
    %{rows: rows} =
      Repo.query!("""
      SELECT data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
        AND column_name = 'data'
      """)

    rows
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  test "down removes the column, up restores it, and each stamps its marker" do
    run(V199.down_statements("public"))
    assert column_shape() == []
    assert marker() == "198"

    run(V199.up_statements("public"))
    assert column_shape() == [["jsonb", "NO", "'{}'::jsonb"]]
    assert marker() == "199"
  end

  test "up is re-runnable" do
    run(V199.up_statements("public"))
    run(V199.up_statements("public"))

    assert column_shape() == [["jsonb", "NO", "'{}'::jsonb"]]
    assert marker() == "199"
  end
end
