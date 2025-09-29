defmodule PhoenixKit.Cache.Registry do
  @moduledoc """
  Registry for managing multiple PhoenixKit.Cache instances.

  This module provides centralized management of cache instances, allowing
  multiple named caches to run simultaneously with different configurations.

  ## Features

  - Centralized cache instance management
  - Support for multiple cache types (settings, roles, modules, etc.)
  - Automatic cache startup and supervision
  - Health checking and monitoring

  ## Usage

      # Start the registry
      {:ok, _} = PhoenixKit.Cache.Registry.start_link()

      # Register cache instances
      PhoenixKit.Cache.Registry.ensure_started(:settings, warmer: &Settings.load_all/0)
      PhoenixKit.Cache.Registry.ensure_started(:user_roles, warmer: &UserRoles.load_all/0)

      # List all cache instances
      PhoenixKit.Cache.Registry.list_caches()

      # Get cache health status
      PhoenixKit.Cache.Registry.health_check()

  """

  use GenServer
  require Logger

  @registry_name __MODULE__

  defstruct caches: %{},
            supervisors: %{}

  @doc """
  Starts the cache registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @registry_name)
  end

  @doc """
  Ensures a cache instance is started with the given configuration.

  If the cache is already running, this function is a no-op.
  If the cache is not running, it will be started automatically.

  ## Options

  Same as PhoenixKit.Cache.start_link/1:
  - `:warmer` - Function to warm the cache on startup
  - `:ttl` - Time-to-live for cache entries
  - `:max_size` - Maximum number of entries

  ## Examples

      PhoenixKit.Cache.Registry.ensure_started(:settings)
      PhoenixKit.Cache.Registry.ensure_started(:user_roles, warmer: &load_user_roles/0)

  """
  @spec ensure_started(atom(), keyword()) :: :ok | {:error, term()}
  def ensure_started(cache_name, opts \\ []) do
    GenServer.call(@registry_name, {:ensure_started, cache_name, opts})
  end

  @doc """
  Lists all managed cache instances with their status.

  ## Examples

      PhoenixKit.Cache.Registry.list_caches()
      # => %{
      #   settings: %{status: :running, pid: #PID<0.123.0>, stats: %{hits: 100, misses: 5}},
      #   user_roles: %{status: :running, pid: #PID<0.124.0>, stats: %{hits: 50, misses: 2}}
      # }

  """
  @spec list_caches() :: map()
  def list_caches do
    GenServer.call(@registry_name, :list_caches)
  end

  @doc """
  Stops a cache instance.

  ## Examples

      PhoenixKit.Cache.Registry.stop_cache(:settings)

  """
  @spec stop_cache(atom()) :: :ok
  def stop_cache(cache_name) do
    GenServer.call(@registry_name, {:stop_cache, cache_name})
  end

  @doc """
  Restarts a cache instance with new configuration.

  ## Examples

      PhoenixKit.Cache.Registry.restart_cache(:settings, ttl: 60_000)

  """
  @spec restart_cache(atom(), keyword()) :: :ok | {:error, term()}
  def restart_cache(cache_name, new_opts \\ []) do
    GenServer.call(@registry_name, {:restart_cache, cache_name, new_opts})
  end

  @doc """
  Performs a health check on all managed caches.

  Returns a map with each cache's health status and basic statistics.

  ## Examples

      PhoenixKit.Cache.Registry.health_check()
      # => %{
      #   overall_status: :healthy,
      #   caches: %{
      #     settings: %{status: :healthy, hit_rate: 0.95, uptime: 3600},
      #     user_roles: %{status: :healthy, hit_rate: 0.88, uptime: 3600}
      #   }
      # }

  """
  @spec health_check() :: map()
  def health_check do
    GenServer.call(@registry_name, :health_check)
  end

  @doc """
  Gets statistics for a specific cache or all caches.

  ## Examples

      PhoenixKit.Cache.Registry.stats(:settings)
      PhoenixKit.Cache.Registry.stats()  # All caches

  """
  @spec stats(atom() | nil) :: map()
  def stats(cache_name \\ nil) do
    GenServer.call(@registry_name, {:stats, cache_name})
  end

  # GenServer Callbacks

  @impl GenServer
  def init(_opts) do
    # Start the dynamic registry for cache processes if not already started
    case Registry.start_link(keys: :unique, name: PhoenixKit.Cache.Registry) do
      {:ok, _registry_pid} ->
        Logger.info("Started PhoenixKit.Cache.Registry")

      {:error, {:already_started, _pid}} ->
        Logger.info("PhoenixKit.Cache.Registry already started")

      {:error, reason} ->
        Logger.error("Failed to start PhoenixKit.Cache.Registry: #{inspect(reason)}")
    end

    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:ensure_started, cache_name, opts}, _from, state) do
    case Map.get(state.caches, cache_name) do
      nil ->
        # Cache not started, start it
        case start_cache(cache_name, opts) do
          {:ok, pid} ->
            new_caches =
              Map.put(state.caches, cache_name, %{
                pid: pid,
                opts: opts,
                started_at: System.monotonic_time(:second)
              })

            {:reply, :ok, %{state | caches: new_caches}}

          {:error, reason} ->
            Logger.error("Failed to start cache #{cache_name}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      cache_info ->
        # Cache already running, check if it's alive
        if Process.alive?(cache_info.pid) do
          {:reply, :ok, state}
        else
          # Process died, restart it
          case start_cache(cache_name, opts) do
            {:ok, pid} ->
              new_cache_info = %{
                cache_info
                | pid: pid,
                  started_at: System.monotonic_time(:second)
              }

              new_caches = Map.put(state.caches, cache_name, new_cache_info)
              {:reply, :ok, %{state | caches: new_caches}}

            {:error, reason} ->
              Logger.error("Failed to restart cache #{cache_name}: #{inspect(reason)}")
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  @impl GenServer
  def handle_call(:list_caches, _from, state) do
    cache_list =
      Enum.reduce(state.caches, %{}, fn {name, info}, acc ->
        status = if Process.alive?(info.pid), do: :running, else: :dead

        stats =
          if status == :running do
            PhoenixKit.Cache.stats(name)
          else
            %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
          end

        Map.put(acc, name, %{
          status: status,
          pid: info.pid,
          started_at: info.started_at,
          opts: info.opts,
          stats: stats
        })
      end)

    {:reply, cache_list, state}
  end

  @impl GenServer
  def handle_call({:stop_cache, cache_name}, _from, state) do
    case Map.get(state.caches, cache_name) do
      nil ->
        {:reply, :ok, state}

      cache_info ->
        if Process.alive?(cache_info.pid) do
          Process.exit(cache_info.pid, :normal)
        end

        new_caches = Map.delete(state.caches, cache_name)
        {:reply, :ok, %{state | caches: new_caches}}
    end
  end

  @impl GenServer
  def handle_call({:restart_cache, cache_name, new_opts}, _from, state) do
    # Stop the existing cache
    case Map.get(state.caches, cache_name) do
      nil ->
        # Cache not running, just start it
        handle_call({:ensure_started, cache_name, new_opts}, nil, state)

      cache_info ->
        if Process.alive?(cache_info.pid) do
          Process.exit(cache_info.pid, :normal)
        end

        # Start with new options
        case start_cache(cache_name, new_opts) do
          {:ok, pid} ->
            new_cache_info = %{
              pid: pid,
              opts: new_opts,
              started_at: System.monotonic_time(:second)
            }

            new_caches = Map.put(state.caches, cache_name, new_cache_info)
            {:reply, :ok, %{state | caches: new_caches}}

          {:error, reason} ->
            Logger.error("Failed to restart cache #{cache_name}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:health_check, _from, state) do
    {healthy_count, total_count, cache_health} =
      Enum.reduce(state.caches, {0, 0, %{}}, fn {name, info}, {healthy, total, acc} ->
        is_healthy = Process.alive?(info.pid)

        stats =
          if is_healthy do
            PhoenixKit.Cache.stats(name)
          else
            %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
          end

        uptime = System.monotonic_time(:second) - info.started_at

        cache_status = %{
          status: if(is_healthy, do: :healthy, else: :unhealthy),
          hit_rate: stats.hit_rate,
          uptime: uptime,
          stats: stats
        }

        {
          if(is_healthy, do: healthy + 1, else: healthy),
          total + 1,
          Map.put(acc, name, cache_status)
        }
      end)

    overall_status =
      cond do
        total_count == 0 -> :no_caches
        healthy_count == total_count -> :healthy
        healthy_count > 0 -> :degraded
        true -> :unhealthy
      end

    result = %{
      overall_status: overall_status,
      healthy_count: healthy_count,
      total_count: total_count,
      caches: cache_health
    }

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:stats, cache_name}, _from, state) do
    result =
      case cache_name do
        nil ->
          # Return stats for all caches
          Enum.reduce(state.caches, %{}, fn {name, info}, acc ->
            if Process.alive?(info.pid) do
              Map.put(acc, name, PhoenixKit.Cache.stats(name))
            else
              Map.put(acc, name, %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0})
            end
          end)

        name ->
          # Return stats for specific cache
          case Map.get(state.caches, name) do
            nil ->
              %{error: :cache_not_found}

            info ->
              if Process.alive?(info.pid) do
                PhoenixKit.Cache.stats(name)
              else
                %{error: :cache_not_running}
              end
          end
      end

    {:reply, result, state}
  end

  # Private Functions

  defp start_cache(cache_name, opts) do
    full_opts = Keyword.put(opts, :name, cache_name)
    PhoenixKit.Cache.start_link(full_opts)
  end
end
