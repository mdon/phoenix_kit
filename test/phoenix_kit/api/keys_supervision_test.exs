defmodule PhoenixKit.API.KeysSupervisionTest do
  @moduledoc """
  `PhoenixKit.Supervisor` starts the API key row cache and the process that
  forgets rows when another node revokes a key.
  """
  use PhoenixKit.DataCase, async: true

  defp child_ids do
    {:ok, {_flags, children}} = PhoenixKit.Supervisor.init(nil)

    Enum.map(children, fn
      %{id: id} -> id
      {module, _arg} -> module
      module when is_atom(module) -> module
    end)
  end

  test "the key row cache is a 60 second PhoenixKit.Cache named :api_keys" do
    {:ok, {_flags, children}} = PhoenixKit.Supervisor.init(nil)

    assert %{start: {PhoenixKit.Cache, :start_link, [opts]}} =
             Enum.find(children, &match?(%{id: :api_keys_cache}, &1))

    assert opts[:name] == :api_keys
    assert opts[:ttl] == 60_000
  end

  test "the cache and its listener start after the PubSub manager, cache first" do
    ids = child_ids()
    position = fn id -> Enum.find_index(ids, &(&1 == id)) end

    assert position.(PhoenixKit.PubSub.Manager) < position.(:api_keys_cache)
    assert position.(:api_keys_cache) < position.(PhoenixKit.API.Keys.Cache)
  end
end
