defmodule PhoenixKit.Migrations.PostgresBelowFloorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  DB-free tests for `PhoenixKit.Migrations.Postgres.plan_up/3` and
  `plan_down/3` — spec §5.2's registry-change cond order.

  `@initial_version` compiles to `1` today (pre-squash), so the guard
  branches these functions exist for are unreachable through the real
  `up/1`/`down/1` (no integer satisfies `0 < v < 1`) — dormant, exactly as
  the task that added this asked. `plan_up/3`/`plan_down/3` take
  `initial_version` as a plain argument rather than reading the module
  attribute, so this suite exercises the guard logic at a synthetic floor
  (121, matching the spec's D2 floor candidate) directly, without needing
  a module-attribute override or a database — the floor becomes real the
  moment `@initial_version` is bumped; nothing here has to change.
  """

  alias PhoenixKit.Migrations.Postgres

  describe "plan_up/3 at floor 1 (today's compiled shape)" do
    test "fresh install (initial 0) runs the full chain, unclamped" do
      assert Postgres.plan_up(0, 161, 1) == {:run, 1..161}
    end

    test "fresh install with version: 0 (pathological pin) clamps to the floor" do
      assert Postgres.plan_up(0, 0, 1) == {:run, 1..1}
    end

    test "fresh install with a negative version (pathological pin) clamps to the floor" do
      assert Postgres.plan_up(0, -5, 1) == {:run, 1..1}
    end

    test "delta upgrade runs from initial + 1 through target" do
      assert Postgres.plan_up(56, 161, 1) == {:run_delta, 57..161}
    end

    test "already at or past target is a no-op" do
      assert Postgres.plan_up(161, 161, 1) == :noop
      assert Postgres.plan_up(161, 100, 1) == :noop
    end

    test "below-floor guard is unreachable at floor 1 (no v satisfies 0 < v < 1)" do
      refute Enum.any?(0..200, fn v -> v > 0 and v < 1 end)
    end
  end

  describe "plan_up/3 at a synthetic floor (dormant-today branch, proven reachable in general)" do
    test "a DB below the floor raises" do
      assert Postgres.plan_up(90, 161, 121) == {:raise, 90, 121}
    end

    test "the floor boundary itself is NOT below-floor" do
      # initial == floor is a valid, already-installed shape (the baseline
      # module IS the floor) — it must fall through to the ordinary delta
      # path, never the raise branch.
      assert Postgres.plan_up(121, 121, 121) == :noop
      assert Postgres.plan_up(121, 161, 121) == {:run_delta, 122..161}
    end

    test "fresh install clamps the target up to the floor" do
      assert Postgres.plan_up(0, 27, 121) == {:run, 121..121}
      assert Postgres.plan_up(0, 161, 121) == {:run, 121..161}
      assert Postgres.plan_up(0, 0, 121) == {:run, 121..121}
    end

    test "delta upgrade from at-or-above the floor is unaffected" do
      assert Postgres.plan_up(130, 161, 121) == {:run_delta, 131..161}
    end
  end

  describe "plan_down/3 at floor 1 (today's compiled shape)" do
    test "teardown degenerates to today's single-range semantics at floor 1" do
      # This is the exact pinning the task asked for: at @initial_version
      # == 1, the {range, floor} split down/1 now performs must produce
      # the SAME flattened version list the old single
      # `current..(target + 1)//-1` range did — see the `{:teardown, ...}`
      # branch's comment in postgres.ex for why it is split at all.
      {:teardown, range, floor} = Postgres.plan_down(161, 0, 1)

      assert Enum.to_list(range) ++ [floor] == Enum.to_list(161..1//-1)
      assert floor == 1
    end

    test "teardown from the floor itself is a single-element degenerate case" do
      {:teardown, range, floor} = Postgres.plan_down(1, 0, 1)

      assert Enum.to_list(range) ++ [floor] == [1]
    end

    test "already at or below target is a no-op" do
      assert Postgres.plan_down(0, 0, 1) == :noop
      assert Postgres.plan_down(50, 100, 1) == :noop
    end

    test "ordinary partial rollback above the floor is unaffected" do
      assert Postgres.plan_down(161, 50, 1) == {:run, 161..51//-1}
    end

    test "below-floor guard and the below-floor clamp are unreachable at floor 1" do
      refute Enum.any?(0..200, fn v -> v > 0 and v < 1 end)
    end
  end

  describe "plan_down/3 at a synthetic floor (dormant-today branches, proven reachable in general)" do
    test "a current version below the floor raises regardless of target" do
      assert Postgres.plan_down(90, 0, 121) == {:raise, 90, 121}
      assert Postgres.plan_down(90, 50, 121) == {:raise, 90, 121}
    end

    test "full teardown splits the range at the floor boundary" do
      assert Postgres.plan_down(161, 0, 121) == {:teardown, 161..122//-1, 121}
    end

    test "the teardown range never includes the floor" do
      {:teardown, range, _floor} = Postgres.plan_down(161, 0, 121)
      refute 121 in Enum.to_list(range)
    end

    test "a target below the floor clamps instead of tearing down" do
      assert Postgres.plan_down(161, 50, 121) == {:clamped, 161..122//-1, 121}
    end

    test "a target at or above the floor is an ordinary partial rollback" do
      assert Postgres.plan_down(161, 130, 121) == {:run, 161..131//-1}
      assert Postgres.plan_down(161, 121, 121) == {:run, 161..122//-1}
    end
  end
end
