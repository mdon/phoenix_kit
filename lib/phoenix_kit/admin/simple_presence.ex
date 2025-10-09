defmodule PhoenixKit.Admin.SimplePresence do
  @moduledoc """
  Unified presence tracking and state storage system for PhoenixKit.

  This module provides:

  1. **Session Presence Tracking** - Track anonymous and authenticated sessions
  2. **Generic Presence Tracking** - Track any resource (editors, viewers, etc.)
  3. **State Storage** - Store temporary data with automatic expiration (5 min TTL)

  Originally designed for admin session tracking, now serves as the universal
  presence + state manager for both admin features and collaborative editing.

  ## Features

  - **Process Monitoring**: Automatic cleanup when tracked processes die
  - **Expiring State**: Stored data auto-expires after 5 minutes
  - **Prefix Queries**: List/count tracked items by prefix pattern
  - **ETS-Based**: Fast in-memory storage without external dependencies

  ## Examples

      # Track an editor for collaborative editing
      SimplePresence.track("editor:entity:5", %{user_email: "user@example.com"})

      # Store form state
      SimplePresence.store_data("state:entity:5", %{name: "Draft", fields: [...]})

      # Retrieve state (returns nil if expired or missing)
      case SimplePresence.get_data("state:entity:5") do
        nil -> # Start fresh
        state -> # Resume with previous state
      end

      # Count active editors
      editor_count = SimplePresence.count_tracked("editor:entity:5")
  """

  use GenServer
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.PubSub.Manager

  @table_name :phoenix_kit_sessions
  @server_name __MODULE__
  @presence_topic "phoenix_kit:presence"

  ## Public API

  @doc """
  Starts the simple presence system.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @server_name)
  end

  @doc """
  Tracks an anonymous session.
  """
  def track_anonymous(session_id, metadata \\ %{}) do
    key = "anonymous:#{session_id}"

    metadata =
      metadata
      |> Map.put(:type, :anonymous)
      |> Map.put(:session_id, session_id)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      :ok ->
        Events.broadcast_anonymous_session_connected(session_id, metadata)
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track anonymous session: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Tracks an authenticated user session.
  """
  def track_user(user, metadata \\ %{}) do
    key = "user:#{user.id}"

    metadata =
      metadata
      |> Map.put(:type, :authenticated)
      |> Map.put(:user_id, user.id)
      |> Map.put(:user_email, user.email)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      :ok ->
        Events.broadcast_user_session_connected(user.id, metadata)
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track user session: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Updates metadata for an existing presence.
  """
  def update_metadata(key, metadata_updates) do
    case GenServer.call(@server_name, {:update, key, metadata_updates}) do
      :ok ->
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  end

  @doc """
  Lists all active sessions.
  """
  def list_active_sessions do
    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, metadata} ->
      # Only include entries that are sessions (have :type and :connected_at)
      Map.has_key?(metadata, :type) && Map.has_key?(metadata, :connected_at)
    end)
    |> Enum.map(fn {_key, metadata} -> metadata end)
    |> Enum.sort_by(& &1.connected_at, {:desc, DateTime})
  rescue
    ArgumentError ->
      []
  end

  @doc """
  Lists anonymous sessions only.
  """
  def list_anonymous_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :anonymous))
  end

  @doc """
  Lists authenticated sessions only.
  """
  def list_authenticated_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :authenticated))
  end

  @doc """
  Gets presence statistics.
  """
  def get_presence_stats do
    active_sessions = list_active_sessions()

    anonymous_sessions = Enum.filter(active_sessions, &(&1.type == :anonymous))
    authenticated_sessions = Enum.filter(active_sessions, &(&1.type == :authenticated))

    # Calculate page statistics
    page_stats =
      active_sessions
      |> Enum.filter(&(not is_nil(&1.current_page)))
      |> Enum.group_by(& &1.current_page)
      |> Enum.map(fn {page, sessions} -> {page, length(sessions)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)

    %{
      total_sessions: length(active_sessions),
      anonymous_sessions: length(anonymous_sessions),
      authenticated_sessions: length(authenticated_sessions),
      unique_anonymous_visitors: length(Enum.uniq_by(anonymous_sessions, & &1.session_id)),
      active_authenticated_users: length(Enum.uniq_by(authenticated_sessions, & &1.user_id)),
      top_pages: page_stats,
      last_updated: DateTime.utc_now()
    }
  end

  @doc """
  Subscribes to presence events.
  """
  def subscribe do
    Manager.subscribe(@presence_topic)
  end

  @doc """
  Gets the presence topic name.
  """
  def get_topic, do: @presence_topic

  ## Generic Tracking API (for collaborative editing)

  @doc """
  Generic tracking function for any use case.

  This allows tracking arbitrary keys (like "entity:5" or "data:10") without
  the opinionated session/user structure.

  ## Examples

      # Track an editor for entity 5
      SimplePresence.track("editor:entity:5", %{user_email: "user@example.com"}, self())

      # Track a viewer
      SimplePresence.track("viewer:page:/admin", %{ip: "127.0.0.1"}, self())
  """
  def track(key, metadata \\ %{}, pid \\ nil) do
    pid = pid || self()

    metadata =
      metadata
      |> Map.put_new(:connected_at, DateTime.utc_now())
      |> Map.put_new(:tracked_at, DateTime.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata, pid}) do
      :ok -> :ok
      error -> error
    end
  rescue
    error ->
      Logger.error("Failed to track #{key}: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Lists all tracked items matching a prefix.

  ## Examples

      # List all editors for entity 5
      SimplePresence.list_tracked("editor:entity:5")

      # List all entity editors
      SimplePresence.list_tracked("editor:entity:")
  """
  def list_tracked(prefix) do
    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {key, metadata} ->
      is_binary(key) && String.starts_with?(key, prefix) &&
        Map.has_key?(metadata, :monitor_ref)
    end)
    |> Enum.map(fn {_key, metadata} -> metadata end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Counts tracked items matching a prefix.

  ## Examples

      # Count editors for entity 5
      SimplePresence.count_tracked("editor:entity:5")
  """
  def count_tracked(prefix) do
    list_tracked(prefix) |> length()
  end

  @doc """
  Untracks a specific key.

  Removes tracking and triggers cleanup. Use when explicitly ending tracking
  before process termination.
  """
  def untrack(key) do
    GenServer.call(@server_name, {:untrack, key})
  end

  ## State Storage API (for collaborative editing)

  @doc """
  Stores arbitrary data associated with a key.

  Data is automatically timestamped and will expire after 5 minutes.
  This is useful for storing unsaved form state during collaborative editing.

  ## Examples

      # Store entity form state
      SimplePresence.store_data("state:entity:5", %{name: "Draft", fields: [...]})

      # Store data form state
      SimplePresence.store_data("state:data:10", %{params: %{...}})
  """
  def store_data(key, data) do
    stored_data = %{
      data: data,
      stored_at: System.monotonic_time(:second)
    }

    :ets.insert(@table_name, {key, stored_data})
    :ok
  rescue
    ArgumentError ->
      Logger.error("Failed to store data for #{key}")
      {:error, :ets_not_available}
  end

  @doc """
  Retrieves data associated with a key.

  Returns nil if:
  - Key doesn't exist
  - Data has expired (>5 minutes old)

  ## Examples

      case SimplePresence.get_data("state:entity:5") do
        nil -> # No data or expired
        data -> # Use data
      end
  """
  def get_data(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, %{data: data, stored_at: stored_at}}] ->
        now = System.monotonic_time(:second)
        age_seconds = now - stored_at

        # Expire after 5 minutes (300 seconds)
        if age_seconds < 300 do
          data
        else
          # Auto-cleanup expired data
          :ets.delete(@table_name, key)
          nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Clears data associated with a key.

  ## Examples

      SimplePresence.clear_data("state:entity:5")
  """
  def clear_data(key) do
    :ets.delete(@table_name, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for session tracking
    :ets.new(@table_name, [:named_table, :public, :set])

    # Schedule cleanup of old sessions every 5 minutes
    schedule_cleanup()

    Logger.debug("PhoenixKit.Admin.SimplePresence started")

    {:ok, %{}}
  end

  @impl true
  def handle_call({:track, key, metadata}, {pid, _ref}, state) do
    # Store session with process monitor (legacy, for track_anonymous/track_user)
    monitor_ref = Process.monitor(pid)
    metadata = Map.put(metadata, :monitor_ref, monitor_ref)

    :ets.insert(@table_name, {key, metadata})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:track, key, metadata, pid}, _from, state) do
    # Store tracking with process monitor (new generic track)
    monitor_ref = Process.monitor(pid)
    metadata = Map.put(metadata, :monitor_ref, monitor_ref)
    metadata = Map.put(metadata, :pid, pid)

    :ets.insert(@table_name, {key, metadata})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:untrack, key}, _from, state) do
    case :ets.lookup(@table_name, key) do
      [{^key, metadata}] ->
        # Demonitor if monitor exists
        if monitor_ref = Map.get(metadata, :monitor_ref) do
          Process.demonitor(monitor_ref, [:flush])
        end

        :ets.delete(@table_name, key)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, key, metadata_updates}, _from, state) do
    case :ets.lookup(@table_name, key) do
      [{^key, existing_metadata}] ->
        updated_metadata = Map.merge(existing_metadata, metadata_updates)
        :ets.insert(@table_name, {key, updated_metadata})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    # Remove session when process dies
    cleanup_session_by_monitor(monitor_ref)
    broadcast_presence_stats()

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_sessions()
    schedule_cleanup()

    {:noreply, state}
  end

  ## Private Functions

  defp broadcast_presence_stats do
    stats = get_presence_stats()
    Events.broadcast_presence_stats_updated(stats)
  end

  defp schedule_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end

  defp cleanup_session_by_monitor(monitor_ref) do
    # Find and remove session by monitor reference
    @table_name
    |> :ets.tab2list()
    |> Enum.find(fn {_key, metadata} ->
      Map.get(metadata, :monitor_ref) == monitor_ref
    end)
    |> case do
      {key, metadata} ->
        :ets.delete(@table_name, key)

        # Broadcast disconnect event only for session entries (not collaborative tracking)
        case Map.get(metadata, :type) do
          :anonymous ->
            Events.broadcast_anonymous_session_disconnected(metadata.session_id)

          :authenticated ->
            Events.broadcast_user_session_disconnected(metadata.user_id, metadata.session_id)

          _ ->
            # Collaborative tracking or other non-session entries - no broadcast needed
            :ok
        end

      nil ->
        :ok
    end
  end

  defp cleanup_old_sessions do
    # Remove sessions older than 1 hour
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, metadata} ->
      # Only cleanup session entries (not collaborative tracking or state data)
      Map.has_key?(metadata, :type) && Map.has_key?(metadata, :connected_at) &&
        DateTime.compare(metadata.connected_at, one_hour_ago) == :lt
    end)
    |> Enum.each(fn {key, metadata} ->
      :ets.delete(@table_name, key)

      # Broadcast disconnect event
      case metadata.type do
        :anonymous ->
          Events.broadcast_anonymous_session_disconnected(metadata.session_id)

        :authenticated ->
          Events.broadcast_user_session_disconnected(metadata.user_id, metadata.session_id)
      end
    end)

    if length(@table_name |> :ets.tab2list()) > 0 do
      broadcast_presence_stats()
    end
  end
end
