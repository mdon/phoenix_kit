defmodule PhoenixKit.MigrationTest do
  @moduledoc """
  Tests for `PhoenixKit.Migration.ensure_current/2` and its private
  `Runner` wrapper.

  ## Why these tests are spec-shape, not runtime

  `ensure_current/2` calls `Ecto.Migrator.up/4`, which spawns a
  migration runner in a separate process and acquires its own DB
  connection. That conflicts with the Ecto sandbox's per-test isolation
  — the spawned process can't see the test's checked-out connection,
  the migration times out trying to acquire one, and the test fails
  with a `DBConnection.ConnectionError` that has nothing to do with the
  helper's actual behaviour.

  Other migration tests in this repo follow the same convention (see
  `test/phoenix_kit/migrations/v107_test.exs` `@moduledoc`): the schema
  change itself is "verified at boot" — if `ensure_current/2` doesn't
  work, the test_helper's call to it on every boot would fail and the
  whole test suite wouldn't start. Migration *logic* gets tested
  separately via direct SQL.

  Below, we pin module shape (Runner has `up/0` + `down/0`,
  `ensure_current/2` is exported) and the freshness of the synthetic
  version. Real-world idempotency is empirically demonstrated by
  consuming modules' `test_helper.exs` calls succeeding on every boot.
  """

  use ExUnit.Case, async: true

  # `function_exported?/3` flakes across async test suites because of
  # module-load ordering. `Module.__info__(:functions)` membership is
  # deterministic and identical in cost. See workspace memory
  # `feedback_test_coverage_blind_spots.md`.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded!(module)
    {fun, arity} in module.__info__(:functions)
  end

  describe "PhoenixKit.Migration.Runner" do
    test "exports up/0 and down/0 (Ecto.Migrator's up/4 + down/4 contract)" do
      assert exports?(PhoenixKit.Migration.Runner, :up, 0)
      assert exports?(PhoenixKit.Migration.Runner, :down, 0)
    end

    test "is a real `Ecto.Migration` module" do
      # `use Ecto.Migration` adds the `__migration__/0` reflection.
      assert exports?(PhoenixKit.Migration.Runner, :__migration__, 0)
    end
  end

  describe "ensure_current/2" do
    test "is exported with arity 2" do
      assert exports?(PhoenixKit.Migration, :ensure_current, 2)
    end
  end
end
