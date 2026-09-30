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

    test "integers pass through, nil means the cache's TTL, a bad zone falls back to UTC" do
      now = ~U[2026-09-30 23:59:00Z]
      assert Cache.ttl_until(5_000, now) == 5_000
      assert Cache.ttl_until(nil, now) == nil
      assert Cache.ttl_until({:end_of_day, "Not/AZone"}, now) == 60_000
    end
  end
end
