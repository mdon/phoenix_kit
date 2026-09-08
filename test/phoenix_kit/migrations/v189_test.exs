defmodule PhoenixKit.Migrations.Postgres.V189Test do
  @moduledoc """
  V189's `billing_default_currency` deletion, run against a seeded settings
  row.

  `V189.up/1` can't be invoked outside an `Ecto.Migrator` runner (same
  constraint as V182Test/V184Test and friends), and by the time any test
  runs the chain has already deleted the row — from an install that had no
  `billing_default_currency` problem to prove in the first place. So the
  migration exposes its statements via `up_statements/1`/`down_statements/1`
  (`up/1` and `down/1` execute exactly those lists), and this suite seeds
  the row back first, then runs the REAL SQL against it.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V189
  alias PhoenixKit.Test.Repo

  @table "phoenix_kit"

  defp seed_billing_default_currency! do
    Repo.query!("""
    INSERT INTO phoenix_kit_settings ("key", "module", "value", "value_json")
    VALUES ('billing_default_currency', 'billing', 'EUR', NULL)
    ON CONFLICT ("key") DO NOTHING
    """)
  end

  defp run_up, do: Enum.each(V189.up_statements("public."), &Repo.query!/1)
  defp run_down, do: Enum.each(V189.down_statements("public."), &Repo.query!/1)

  defp billing_default_currency_count do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM phoenix_kit_settings WHERE \"key\" = 'billing_default_currency'"
      )

    count
  end

  defp billing_default_currency_value do
    case Repo.query!(
           "SELECT value FROM phoenix_kit_settings WHERE \"key\" = 'billing_default_currency'"
         ) do
      %{rows: [[value]]} -> value
      %{rows: []} -> nil
    end
  end

  defp table_marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('#{@table}'::regclass)")
    marker
  end

  test "up deletes the dead billing_default_currency setting and stamps the version marker" do
    seed_billing_default_currency!()
    assert billing_default_currency_count() == 1

    run_up()

    assert billing_default_currency_count() == 0
    assert table_marker() == "189"
  end

  test "is a no-op when the row is already absent (a fresh install has never seeded it)" do
    assert billing_default_currency_count() == 0

    run_up()

    assert billing_default_currency_count() == 0
    assert table_marker() == "189"
  end

  test "down restores the row exactly as V135 seeded it, and stamps the prior marker" do
    seed_billing_default_currency!()
    run_up()
    assert billing_default_currency_count() == 0

    run_down()

    assert billing_default_currency_count() == 1
    assert billing_default_currency_value() == "EUR"
    assert table_marker() == "188"
  end

  test "down never clobbers a value an operator re-created by hand" do
    seed_billing_default_currency!()
    run_up()
    assert billing_default_currency_count() == 0

    # A host re-creates the setting by hand after the deletion, with a value
    # that is not the V135 default — e.g. it configured a real billing
    # currency under this key before ever seeing this migration.
    Repo.query!("""
    INSERT INTO phoenix_kit_settings ("key", "module", "value", "value_json")
    VALUES ('billing_default_currency', 'billing', 'USD', NULL)
    """)

    run_down()

    # ON CONFLICT DO NOTHING: the hand-created row survives untouched.
    assert billing_default_currency_value() == "USD"
    assert table_marker() == "188"
  end
end
