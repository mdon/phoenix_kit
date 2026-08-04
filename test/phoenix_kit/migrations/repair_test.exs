defmodule PhoenixKit.Migrations.RepairTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Migrations.Repair

  # No `Application.put_env(:phoenix_kit, :expected_schema_module, ...)` here
  # at all — this exercises the REAL end-to-end degradation, not just
  # `Resolver` in isolation: `PhoenixKit.Migrations.ExpectedSchema` genuinely
  # does not exist in this repository (P2, pending the squash PR's
  # scratch-DB generation step), so `verify/1`/`repair/1` must hit the
  # not-generated fast path before ever touching a repo — no database
  # needed to prove it. `async: false` because this depends on that env var
  # being *unset* for the duration of the test, and
  # `PhoenixKit.Migrations.ExpectedSchema.ResolverTest` (elsewhere in this
  # suite) mutates it — both files being `async: false` is what guarantees
  # they never interleave.
  describe "manifest not generated (today's actual repository state)" do
    test "verify/1 returns {:error, :not_generated} without touching a repo" do
      assert Repair.verify() == {:error, :not_generated}
    end

    test "repair/1 returns {:error, :not_generated} without touching a repo" do
      assert Repair.repair() == {:error, :not_generated}
    end

    test "the fast path fires before prefix validation — an invalid prefix does not raise instead" do
      assert Repair.verify(prefix: "Not Valid!") == {:error, :not_generated}
    end
  end

  # Deliberately no "manifest resolves, then hits the repo" describe block
  # here: once `PhoenixKit.Migrations.ExpectedSchema.Resolver.resolve/0`
  # succeeds, every further step needs a real connection (`repo.config/0`,
  # `PhoenixKit.Migrations.Repair.Environment.pooled?/2`'s checkout) — this
  # repo's test suite runs with no PostgreSQL (per `test/test_helper.exs`),
  # and exercising that path even just to observe it fail would mean
  # touching connection-pool machinery from a unit test. That combination
  # only becomes testable with a real database — see
  # `test/integration/repair_test.exs`.

  describe "error_message/1 — every error_reason() this module returns renders to text" do
    test ":not_generated" do
      assert Repair.error_message(:not_generated) =~ "not generated yet"
    end

    test "{:not_installed, prefix}" do
      assert Repair.error_message({:not_installed, "public"}) =~ "not installed"
    end

    test "{:below_floor, comment, floor}" do
      message = Repair.error_message({:below_floor, 90, 121})
      assert message =~ "90"
      assert message =~ "121"
      assert message =~ "migration bridge"
    end

    test "{:above_current, comment, current}" do
      message = Repair.error_message({:above_current, 200, 151})
      assert message =~ "200"
      assert message =~ "151"
    end

    test "{:pooled_connection, message}" do
      assert Repair.error_message({:pooled_connection, "custom text"}) == "custom text"
    end

    test "{:concurrent_migration, before, after}" do
      assert Repair.error_message({:concurrent_migration, 135, 142}) =~ "concurrent"
    end
  end
end
