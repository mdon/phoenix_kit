defmodule PhoenixKit.CacheRememberTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Cache

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    :ok
  end

  defp start_cache(opts \\ []) do
    name = :"remember_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, Keyword.put(opts, :name, name)}, id: name)
    name
  end

  defp flush(cache), do: Cache.stats(cache)

  test "computes on a miss, then serves the cached value" do
    cache = start_cache()
    counter = :counters.new(1, [])
    fun = fn -> :counters.add(counter, 1, 1) && :computed end

    assert Cache.remember(cache, "k", fun) == :computed
    flush(cache)
    assert Cache.remember(cache, "k", fun) == :computed
    assert :counters.get(counter, 1) == 1
  end

  test "a cached nil is a hit" do
    cache = start_cache()
    assert Cache.remember(cache, "k", fn -> nil end) == nil
    flush(cache)
    assert Cache.remember(cache, "k", fn -> flunk("recomputed a cached nil") end) == nil
  end

  test "until: ms expires the entry" do
    cache = start_cache()
    Cache.remember(cache, "k", fn -> :first end, until: 30)
    flush(cache)
    Process.sleep(60)
    assert Cache.remember(cache, "k", fn -> :second end) == :second
  end

  test "an invalidation during the computation is not overwritten by its result" do
    cache = start_cache()

    value =
      Cache.remember(cache, "k", fn ->
        :ok = Cache.invalidate_now(cache, ["k"])
        :stale
      end)

    assert value == :stale
    flush(cache)
    assert Cache.get(cache, "k", :miss) == :miss
  end

  describe "ttl_until/2" do
    test "end_of_minute / end_of_hour on the zone's wall clock" do
      now = ~U[2026-09-30 09:15:42.500Z]
      assert Cache.ttl_until({:end_of_minute, "Europe/Tallinn"}, now) == 17_500
      assert Cache.ttl_until({:end_of_hour, "Europe/Tallinn"}, now) == (44 * 60 + 17) * 1000 + 500
    end

    test "end_of_day is local midnight, not UTC midnight" do
      # 21:30 UTC is 00:30 the next day in Tallinn (UTC+3 in summer).
      now = ~U[2026-09-30 21:30:00Z]
      assert Cache.ttl_until({:end_of_day, "Europe/Tallinn"}, now) == 23 * 3_600_000 + 30 * 60_000
    end

    test "a day that is 25 hours long because the clocks go back" do
      # Tallinn leaves summer time on 2026-10-25: that local day lasts 25h.
      midnight_local = ~U[2026-10-24 21:00:00Z]
      assert Cache.ttl_until({:end_of_day, "Europe/Tallinn"}, midnight_local) == 25 * 3_600_000
    end

    # Tallinn's clocks go back at 04:00 EEST -> 03:00 EET on 2026-10-25 (01:00Z),
    # so 03:00-03:59 happens twice. A minute or an hour is counted on the wall
    # clock, never re-resolved from a wall time that names two instants.
    test "end_of_minute in the second pass of the repeated hour" do
      # 01:30:10Z is 03:30:10 EET, after the clocks went back.
      assert Cache.ttl_until({:end_of_minute, "Europe/Tallinn"}, ~U[2026-10-25 01:30:10Z]) ==
               50_000
    end

    test "end_of_hour in the first pass of the repeated hour" do
      # 00:30Z is 03:30 EEST; the wall-clock hour is 30 minutes from over.
      assert Cache.ttl_until({:end_of_hour, "Europe/Tallinn"}, ~U[2026-10-25 00:30:00Z]) ==
               30 * 60_000
    end

    test "end_of_hour in the second pass of the repeated hour" do
      # 01:15Z is 03:15 EET: 45 minutes left, not the 15 that already passed.
      assert Cache.ttl_until({:end_of_hour, "Europe/Tallinn"}, ~U[2026-10-25 01:15:00Z]) ==
               45 * 60_000
    end

    test "an hour boundary in a zone with a half-hour offset" do
      # 10:10Z is 15:40 in Kolkata (UTC+5:30); the wall-clock hour ends at 16:00.
      assert Cache.ttl_until({:end_of_hour, "Asia/Kolkata"}, ~U[2026-09-30 10:10:00Z]) ==
               20 * 60_000
    end

    test "a bad zone makes minutes and hours UTC too" do
      assert Cache.ttl_until({:end_of_minute, "Not/AZone"}, ~U[2026-09-30 10:10:45Z]) == 15_000
      assert Cache.ttl_until({:end_of_hour, "Not/AZone"}, ~U[2026-09-30 10:10:00Z]) == 50 * 60_000
    end

    test "integers pass through, nil means the cache's TTL, a bad zone falls back to UTC" do
      now = ~U[2026-09-30 23:59:00Z]
      assert Cache.ttl_until(5_000, now) == 5_000
      assert Cache.ttl_until(nil, now) == nil
      assert Cache.ttl_until({:end_of_day, "Not/AZone"}, now) == 60_000
    end
  end

  test "an error is returned but not stored, so the next call loads again" do
    cache = start_cache()

    assert Cache.remember(cache, :k, fn -> {:error, :timeout} end) == {:error, :timeout}
    flush(cache)
    assert Cache.remember(cache, :k, fn -> {:ok, :recovered} end) == {:ok, :recovered}
    flush(cache)
    assert Cache.remember(cache, :k, fn -> {:ok, :again} end) == {:ok, :recovered}

    assert Cache.remember(cache, :e, fn -> :error end) == :error
    flush(cache)
    assert Cache.remember(cache, :e, fn -> :fine end) == :fine
  end
end
