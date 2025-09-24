defmodule PhoenixKit.Settings.Cache do
  @moduledoc """
  ETS-based cache for PhoenixKit settings to optimize database queries.

  This module provides a high-performance in-memory cache for settings using ETS
  (Erlang Term Storage) with automatic cache warming and invalidation.

  ## Features

  - **Fast Lookups**: Sub-millisecond ETS lookups vs. database queries
  - **Automatic Warming**: Cache populated on startup from database
  - **Smart Invalidation**: Cache updated when settings change
  - **Fallback Strategy**: Falls back to database if cache miss
  - **Concurrency Safe**: ETS provides concurrent read access

  ## Usage

      # Get a cached setting (preferred method)
      PhoenixKit.Settings.Cache.get("date_format", "Y-m-d")

      # Get multiple settings at once (most efficient)
      PhoenixKit.Settings.Cache.get_multiple(["date_format", "time_format"])

      # Invalidate cache when settings change
      PhoenixKit.Settings.Cache.invalidate("date_format")

  ## Performance

  - **Cache Hit**: ~0.001ms (sub-millisecond)
  - **Database Query**: ~0.1-0.6ms (100-600x slower)
  - **Memory Usage**: Minimal (~1KB for typical settings)

  ## Cache Lifecycle

  1. **Startup**: Cache warmed from database in GenServer init
  2. **Runtime**: Fast ETS lookups with database fallback
  3. **Updates**: Cache invalidated and refreshed on setting changes
  4. **Restart**: Cache rebuilt automatically on GenServer restart
  """

  use GenServer
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Setting

  @table_name :phoenix_kit_settings_cache
  # Refresh cache every hour as backup
  @cache_ttl :timer.minutes(60)

  ## Client API

  @doc """
  Starts the settings cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a setting value from cache with fallback to database.

  Returns the cached value if available, otherwise queries the database
  and caches the result for future lookups.

  ## Examples

      iex> PhoenixKit.Settings.Cache.get("date_format", "Y-m-d")
      "F j, Y"

      iex> PhoenixKit.Settings.Cache.get("non_existent", "default")
      "default"
  """
  def get(key, default \\ nil) when is_binary(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, _timestamp}] ->
        value

      [] ->
        # Cache miss - query database and cache result
        value = query_and_cache_setting(key)
        value || default
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist (server not started) - try to start it or fallback
      case ensure_cache_started() do
        :ok ->
          # Retry the lookup after starting cache
          case :ets.lookup(@table_name, key) do
            [{^key, value, _timestamp}] -> value || default
            [] -> query_and_cache_setting(key) || default
          end

        :error ->
          # Fallback to database if cache can't be started
          Logger.warning("Settings cache not available, falling back to database")
          query_database_directly(key) || default
      end
  end

  @doc """
  Gets multiple settings from cache in a single operation.

  More efficient than multiple individual get/2 calls when you need
  several settings at once.

  ## Examples

      iex> PhoenixKit.Settings.Cache.get_multiple(["date_format", "time_format"])
      %{"date_format" => "F j, Y", "time_format" => "h:i A"}

      iex> PhoenixKit.Settings.Cache.get_multiple(["date_format", "time_format"], %{"date_format" => "Y-m-d"})
      %{"date_format" => "F j, Y", "time_format" => "H:i"}
  """
  def get_multiple(keys, defaults \\ %{}) when is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      default = Map.get(defaults, key)
      value = get(key, default)
      Map.put(acc, key, value)
    end)
  end

  @doc """
  Invalidates a specific setting in the cache.

  Forces the next lookup to query the database and refresh the cache.
  Called automatically when settings are updated.

  ## Examples

      iex> PhoenixKit.Settings.Cache.invalidate("date_format")
      :ok
  """
  def invalidate(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @doc """
  Invalidates multiple settings in the cache.

  ## Examples

      iex> PhoenixKit.Settings.Cache.invalidate_multiple(["date_format", "time_format"])
      :ok
  """
  def invalidate_multiple(keys) when is_list(keys) do
    GenServer.cast(__MODULE__, {:invalidate_multiple, keys})
  end

  @doc """
  Clears the entire cache and rebuilds it from the database.

  Useful for bulk setting updates or cache corruption recovery.

  ## Examples

      iex> PhoenixKit.Settings.Cache.refresh_all()
      :ok
  """
  def refresh_all do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  @doc """
  Gets cache statistics for monitoring and debugging.

  ## Examples

      iex> PhoenixKit.Settings.Cache.stats()
      %{
        cache_size: 3,
        table_info: [size: 3, memory: 512],
        last_refresh: ~U[2024-01-15 10:30:00Z]
      }
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS table for fast concurrent reads
    table =
      :ets.new(@table_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    # Warm cache from database
    case warm_cache() do
      :ok ->
        Logger.info("Settings cache initialized with #{:ets.info(table, :size)} settings")
        schedule_refresh()
        {:ok, %{table: table, last_refresh: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.error("Failed to initialize settings cache: #{inspect(reason)}")
        {:ok, %{table: table, last_refresh: nil}}
    end
  end

  @impl true
  def handle_cast({:invalidate, key}, state) do
    :ets.delete(@table_name, key)
    Logger.debug("Invalidated cache for setting: #{key}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:invalidate_multiple, keys}, state) do
    Enum.each(keys, &:ets.delete(@table_name, &1))
    Logger.debug("Invalidated cache for settings: #{inspect(keys)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    :ets.delete_all_objects(@table_name)
    warm_cache()
    new_state = %{state | last_refresh: DateTime.utc_now()}
    Logger.info("Refreshed entire settings cache")
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    table_info = :ets.info(@table_name)

    stats = %{
      cache_size: :ets.info(@table_name, :size),
      table_info: Keyword.take(table_info, [:size, :memory]),
      last_refresh: state.last_refresh
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:refresh_cache, state) do
    warm_cache()
    schedule_refresh()
    new_state = %{state | last_refresh: DateTime.utc_now()}
    {:noreply, new_state}
  end

  ## Private Implementation

  # Warms the cache by loading all settings from database
  defp warm_cache do
    repo = RepoHelper.repo()
    settings = repo.all(Setting)

    timestamp = DateTime.utc_now()

    Enum.each(settings, fn setting ->
      :ets.insert(@table_name, {setting.key, setting.value, timestamp})
    end)

    :ok
  rescue
    error ->
      Logger.error("Failed to warm settings cache: #{inspect(error)}")
      {:error, error}
  end

  # Queries database for a single setting and caches the result
  defp query_and_cache_setting(key) do
    repo = RepoHelper.repo()

    case repo.get_by(Setting, key: key) do
      %Setting{value: value} ->
        timestamp = DateTime.utc_now()
        :ets.insert(@table_name, {key, value, timestamp})
        value

      nil ->
        # Cache the fact that this setting doesn't exist to avoid repeated queries
        timestamp = DateTime.utc_now()
        :ets.insert(@table_name, {key, nil, timestamp})
        nil
    end
  rescue
    error ->
      Logger.error("Failed to query setting #{key}: #{inspect(error)}")
      nil
  end

  # Direct database query without caching (fallback only)
  defp query_database_directly(key) do
    repo = RepoHelper.repo()

    case repo.get_by(Setting, key: key) do
      %Setting{value: value} -> value
      nil -> nil
    end
  rescue
    _error -> nil
  end

  # Schedules periodic cache refresh
  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @cache_ttl)
  end

  # Ensures the cache GenServer is started (for library usage)
  defp ensure_cache_started do
    case GenServer.whereis(__MODULE__) do
      nil ->
        # Try to start the cache GenServer
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> :error
        end

      _pid ->
        :ok
    end
  rescue
    _error -> :error
  end
end
