defmodule PhoenixKitWeb.Live.DashboardLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Users.{Roles, Sessions}

  def mount(_params, session, socket) do
    # Subscribe to statistics updates for live data
    if connected?(socket) do
      Events.subscribe_to_stats()
      Events.subscribe_to_sessions()
    end

    # Load extended statistics including activity and confirmation status (now optimized!)
    stats = Roles.get_extended_stats()
    session_stats = Sessions.get_session_stats()

    # Get PhoenixKit version from application specification
    version = Application.spec(:phoenix_kit, :vsn) |> to_string()

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Cache user roles from scope to avoid repeated DB queries
    user_roles =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{cached_roles: cached_roles} when is_list(cached_roles) -> cached_roles
        _ -> []
      end

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:session_stats, session_stats)
      |> assign(:phoenix_kit_version, version)
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Dashboard")
      |> assign(:cached_user_roles, user_roles)

    {:ok, socket}
  end

  defp get_current_path(_socket, _session) do
    # For DashboardLive, always return dashboard path
    "/phoenix_kit/admin/dashboard"
  end

  def handle_event("refresh_stats", _params, socket) do
    # Refresh statistics with optimized single query
    stats = Roles.get_extended_stats()
    session_stats = Sessions.get_session_stats()

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:session_stats, session_stats)
      |> assign(:stats_last_updated, :os.system_time(:second))
      |> put_flash(:info, "Statistics refreshed successfully")

    {:noreply, socket}
  end

  # Handle live statistics updates from PubSub
  def handle_info({:stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:stats_last_updated, :os.system_time(:second))

    {:noreply, socket}
  end

  # Handle live session statistics updates from PubSub
  def handle_info({:sessions_stats_updated, session_stats}, socket) do
    socket =
      socket
      |> assign(:session_stats, session_stats)

    {:noreply, socket}
  end
end
