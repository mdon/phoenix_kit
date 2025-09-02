defmodule PhoenixKit.Admin.Presence do
  @moduledoc """
  Phoenix.Presence implementation for tracking anonymous and authenticated sessions.

  This module provides real-time tracking of:
  - Anonymous visitors (WebSocket connections without user_id)
  - Authenticated users (with user_id)
  - Session details like IP, User-Agent, current page, connection time

  ## Usage

  Track anonymous session:
  ```elixir
  PhoenixKit.Admin.Presence.track_anonymous(socket, session_id, %{
    connected_at: DateTime.utc_now(),
    ip_address: get_connect_info(socket, :peer_data).address,
    user_agent: get_connect_info(socket, :user_agent),
    current_page: socket.assigns.current_path
  })
  ```

  Track authenticated session:
  ```elixir  
  PhoenixKit.Admin.Presence.track_user(socket, user, %{
    connected_at: DateTime.utc_now(),
    session_id: session_id,
    ip_address: get_connect_info(socket, :peer_data).address
  })
  ```

  ## Events Generated

  - `{:anonymous_session_connected, session_id, session_info}`
  - `{:anonymous_session_disconnected, session_id}`  
  - `{:user_session_connected, user_id, session_info}`
  - `{:user_session_disconnected, user_id, session_id}`
  - `{:presence_stats_updated, stats}`
  """

  use Phoenix.Presence,
    otp_app: :phoenix_kit,
    pubsub_server: :phoenix_kit_internal_pubsub

  alias PhoenixKit.Admin.Events

  # Presence topic for tracking all sessions
  @presence_topic "phoenix_kit:presence"

  @doc """
  Tracks an anonymous session in Presence.

  ## Parameters
  - `socket` - Phoenix LiveView socket
  - `session_id` - Unique session identifier  
  - `metadata` - Session metadata map

  ## Metadata Fields
  - `:connected_at` - Connection timestamp
  - `:ip_address` - Client IP address
  - `:user_agent` - Browser User-Agent string
  - `:current_page` - Current page path
  """
  def track_anonymous(socket, session_id, metadata \\ %{}) do
    key = "anonymous:#{session_id}"

    metadata =
      metadata
      |> Map.put(:type, :anonymous)
      |> Map.put(:session_id, session_id)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case track(socket, @presence_topic, key, metadata) do
      {:ok, _ref} ->
        Events.broadcast_anonymous_session_connected(session_id, metadata)
        broadcast_presence_stats()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Tracks an authenticated user session in Presence.

  ## Parameters
  - `socket` - Phoenix LiveView socket
  - `user` - User struct with id and email
  - `metadata` - Session metadata map

  ## Metadata Fields
  - `:connected_at` - Connection timestamp
  - `:session_id` - Session identifier
  - `:ip_address` - Client IP address  
  - `:user_agent` - Browser User-Agent string
  - `:current_page` - Current page path
  """
  def track_user(socket, user, metadata \\ %{}) do
    key = "user:#{user.id}"

    metadata =
      metadata
      |> Map.put(:type, :authenticated)
      |> Map.put(:user_id, user.id)
      |> Map.put(:user_email, user.email)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case track(socket, @presence_topic, key, metadata) do
      {:ok, _ref} ->
        Events.broadcast_user_session_connected(user.id, metadata)
        broadcast_presence_stats()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates metadata for an existing presence.

  Useful for updating current page or other session details.
  """
  def update_metadata(socket, key, metadata_updates) do
    case update(socket, @presence_topic, key, fn metadata ->
           Map.merge(metadata, metadata_updates)
         end) do
      {:ok, _ref} ->
        broadcast_presence_stats()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets all currently active sessions (anonymous + authenticated).

  Returns a list of session maps with type, metadata, and connection info.
  """
  def list_active_sessions do
    @presence_topic
    |> list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} ->
      Enum.map(metas, fn meta ->
        %{
          type: meta.type,
          session_id: Map.get(meta, :session_id),
          user_id: Map.get(meta, :user_id),
          user_email: Map.get(meta, :user_email),
          connected_at: meta.connected_at,
          ip_address: Map.get(meta, :ip_address),
          user_agent: Map.get(meta, :user_agent),
          current_page: Map.get(meta, :current_page),
          phx_ref: meta.phx_ref
        }
      end)
    end)
    |> Enum.sort_by(& &1.connected_at, {:desc, DateTime})
  end

  @doc """
  Gets all anonymous sessions currently tracked.
  """
  def list_anonymous_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :anonymous))
  end

  @doc """
  Gets all authenticated user sessions currently tracked.
  """
  def list_authenticated_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :authenticated))
  end

  @doc """
  Gets presence statistics.

  Returns statistics about current active sessions:
  - Total sessions
  - Anonymous sessions count
  - Authenticated sessions count  
  - Unique anonymous visitors
  - Active authenticated users
  - Top pages by activity
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
  Subscribes to presence events for real-time updates.
  """
  def subscribe do
    PhoenixKit.PubSub.Manager.subscribe(@presence_topic)
  end

  @doc """
  Gets the presence topic name.
  """
  def get_topic, do: @presence_topic

  ## Private Functions

  defp broadcast_presence_stats do
    stats = get_presence_stats()
    Events.broadcast_presence_stats_updated(stats)
  end

  ## Phoenix.Presence Callbacks

  def init(_opts) do
    {:ok, %{}}
  end

  def handle_metas(topic, %{joins: joins, leaves: leaves}, _presences, state) do
    # Handle joins
    for {key, %{metas: [meta | _]}} <- joins do
      handle_join(topic, key, meta)
    end

    # Handle leaves  
    for {key, %{metas: [meta | _]}} <- leaves do
      handle_leave(topic, key, meta)
    end

    {:ok, state}
  end

  defp handle_join(@presence_topic, "anonymous:" <> session_id, _meta) do
    Events.broadcast_anonymous_session_connected(session_id, %{})
    broadcast_presence_stats()
  end

  defp handle_join(@presence_topic, "user:" <> user_id, _meta) do
    case Integer.parse(user_id) do
      {user_id_int, ""} ->
        Events.broadcast_user_session_connected(user_id_int, %{})
        broadcast_presence_stats()

      _ ->
        :ok
    end
  end

  defp handle_join(_, _, _), do: :ok

  defp handle_leave(@presence_topic, "anonymous:" <> session_id, _meta) do
    Events.broadcast_anonymous_session_disconnected(session_id)
    broadcast_presence_stats()
  end

  defp handle_leave(@presence_topic, "user:" <> user_id, meta) do
    case Integer.parse(user_id) do
      {user_id_int, ""} ->
        session_id = Map.get(meta, :session_id)
        Events.broadcast_user_session_disconnected(user_id_int, session_id)
        broadcast_presence_stats()

      _ ->
        :ok
    end
  end

  defp handle_leave(_, _, _), do: :ok
end
