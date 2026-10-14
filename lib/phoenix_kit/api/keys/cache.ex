defmodule PhoenixKit.API.Keys.Cache do
  @moduledoc """
  A 60 second cache of API key rows, keyed by token prefix.

  Verifying a key on every request would otherwise cost a query per call. The
  cached row carries the owner uuid, scopes, flags, IP allow-list, expiry and
  revocation time. **Owner rights are never cached**: they are computed on every
  request (`PhoenixKit.API.Keys.effective_scopes/1`), so blocking, deleting or
  demoting the owner takes effect on the next request even while the row is
  cached.

  The rows live in a `PhoenixKit.Cache` instance named `:api_keys`, which
  `PhoenixKit.Supervisor` starts. Changing a key (revoke, rotate) calls
  `invalidate/1`, which drops the row on this node at once and broadcasts the
  prefix over PubSub; this module is also a small process that listens for those
  broadcasts and drops the row on the other nodes. Without the cache process
  `fetch/2` simply reads the database every time.

  `touch_last_used?/1` answers whether `last_used_at` may be written now, at
  most once per minute per key.
  """

  use GenServer

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Users.RateLimiter.Backend

  @cache :api_keys
  @topic "phoenix_kit:api_keys"
  @miss {:error, :api_key_not_found}
  @touch_window_ms 60_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the key row for `prefix`, from the cache or from `loader`.

  A `nil` from `loader` is returned as `nil` and is **not** cached, so a key
  created a moment after a failed lookup is found at once.
  """
  @spec fetch(String.t(), (-> struct() | nil)) :: struct() | nil
  def fetch(prefix, loader) when is_binary(prefix) and is_function(loader, 0) do
    case PhoenixKit.Cache.remember(@cache, prefix, fn -> loader.() || @miss end) do
      @miss -> nil
      key -> key
    end
  end

  @doc """
  Forgets the row for `prefix` on this node and tells the other nodes to do so.

  Never raises: a missing cache or PubSub is logged by the layer below and the
  row then expires on its own within 60 seconds.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(prefix) when is_binary(prefix) do
    PhoenixKit.Cache.invalidate_now(@cache, [prefix])
    broadcast(prefix)
    :ok
  end

  @doc """
  Whether `last_used_at` of this key may be written now.

  True at most once per minute per key on this node.
  """
  @spec touch_last_used?(String.t()) :: boolean()
  def touch_last_used?(key_uuid) when is_binary(key_uuid) do
    match?({:allow, _}, Backend.hit("api:key_touch:" <> key_uuid, @touch_window_ms, 1))
  end

  @impl GenServer
  def init(_opts) do
    PubSubManager.subscribe(@topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:api_key_invalidated, prefix}, state) do
    PhoenixKit.Cache.invalidate_now(@cache, [prefix])
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp broadcast(prefix) do
    PubSubManager.broadcast(@topic, {:api_key_invalidated, prefix})
  rescue
    _ -> :ok
  end
end
