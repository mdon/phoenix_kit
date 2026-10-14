defmodule PhoenixKit.API.Keys.CacheTest do
  @moduledoc """
  The key row cache: fills on a miss, never stores "not found", forgets a prefix
  on `invalidate/1` and on a PubSub broadcast from another node, and allows the
  `last_used_at` write once a minute.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.PubSub.Manager, as: PubSubManager

  @topic "phoenix_kit:api_keys"

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{prefix: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower), counter: counter}
  end

  defp loader(counter, value) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      value
    end
  end

  defp loads(counter), do: Agent.get(counter, & &1)

  test "loads once and then answers from the cache", %{prefix: prefix, counter: counter} do
    key = %Key{prefix: prefix, name: "cached"}

    assert Cache.fetch(prefix, loader(counter, key)) == key
    assert Cache.fetch(prefix, loader(counter, key)) == key
    assert Cache.fetch(prefix, loader(counter, key)) == key

    assert loads(counter) == 1
  end

  test "does not cache a prefix that has no key", %{prefix: prefix, counter: counter} do
    assert Cache.fetch(prefix, loader(counter, nil)) == nil
    assert Cache.fetch(prefix, loader(counter, nil)) == nil
    assert loads(counter) == 2

    # The key appears later: it is found at once.
    key = %Key{prefix: prefix, name: "late"}
    assert Cache.fetch(prefix, loader(counter, key)) == key
  end

  test "invalidate/1 makes the next fetch load again", %{prefix: prefix, counter: counter} do
    old = %Key{prefix: prefix, name: "old"}
    new = %Key{prefix: prefix, name: "new"}

    assert Cache.fetch(prefix, loader(counter, old)) == old
    assert :ok = Cache.invalidate(prefix)
    assert Cache.fetch(prefix, loader(counter, new)) == new
    assert loads(counter) == 2
  end

  test "invalidating one prefix leaves the others", %{prefix: prefix, counter: counter} do
    other = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    key = %Key{prefix: prefix, name: "kept"}
    other_key = %Key{prefix: other, name: "other"}

    Cache.fetch(prefix, loader(counter, key))
    Cache.fetch(other, loader(counter, other_key))
    Cache.invalidate(other)

    assert Cache.fetch(prefix, loader(counter, nil)) == key
  end

  test "invalidate/1 tells the other nodes", %{prefix: prefix} do
    PubSubManager.subscribe(@topic)

    assert :ok = Cache.invalidate(prefix)

    assert_receive {:api_key_invalidated, ^prefix}
  end

  test "a broadcast from another node drops the row on this one", %{
    prefix: prefix,
    counter: counter
  } do
    key = %Key{prefix: prefix, name: "remote"}
    replacement = %Key{prefix: prefix, name: "replacement"}

    assert Cache.fetch(prefix, loader(counter, key)) == key

    # What `invalidate/1` sends to the other nodes; here it is the only message.
    PubSubManager.broadcast(@topic, {:api_key_invalidated, prefix})
    # The listener has handled everything sent before this call returns.
    _ = :sys.get_state(Cache)

    assert Cache.fetch(prefix, loader(counter, replacement)) == replacement
  end

  test "without a cache process every fetch reads the database", %{
    prefix: prefix,
    counter: counter
  } do
    stop_supervised!(PhoenixKit.Cache)
    key = %Key{prefix: prefix, name: "uncached"}

    assert Cache.fetch(prefix, loader(counter, key)) == key
    assert Cache.fetch(prefix, loader(counter, key)) == key
    assert loads(counter) == 2
  end

  describe "touch_last_used?/1" do
    test "is true once per key and minute" do
      uuid = UUIDv7.generate()

      assert Cache.touch_last_used?(uuid)
      refute Cache.touch_last_used?(uuid)
      refute Cache.touch_last_used?(uuid)
    end

    test "is tracked per key" do
      assert Cache.touch_last_used?(UUIDv7.generate())
      assert Cache.touch_last_used?(UUIDv7.generate())
    end
  end
end
