defmodule PhoenixKitWeb.Live.AnonymousSessionsLive do
  @moduledoc """
  Live component for viewing anonymous session activity in the PhoenixKit admin panel.

  This module provides functionality to:
  - View all active anonymous sessions in real-time
  - Monitor session details including IP, User-Agent, connection time, and current page
  - Track session statistics and visitor behavior
  - Display geographic distribution (by IP)
  - Show page activity patterns

  Only accessible to users with Owner or Admin roles.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.{Events, Presence}

  @per_page 15

  def mount(_params, session, socket) do
    # Subscribe to presence events for real-time updates
    if connected?(socket) do
      Events.subscribe_to_presence()
    end

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search_query, "")
      |> assign(:filter_type, "all")
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Anonymous Sessions")
      |> assign(:sort_by, :connected_at)
      |> assign(:sort_order, :desc)
      |> load_sessions()
      |> load_presence_stats()

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("search", %{"search" => search_query}, socket) do
    socket =
      socket
      |> assign(:search_query, search_query)
      |> assign(:page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("filter_by_type", %{"type" => type}, socket) do
    socket =
      socket
      |> assign(:filter_type, type)
      |> assign(:page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("sort_by", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    
    {sort_by, sort_order} =
      if socket.assigns.sort_by == field_atom do
        {field_atom, toggle_sort_order(socket.assigns.sort_order)}
      else
        {field_atom, :desc}
      end

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_order, sort_order)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("refresh_sessions", _params, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_presence_stats()
      |> put_flash(:info, "Sessions refreshed successfully")

    {:noreply, socket}
  end

  defp load_sessions(socket) do
    all_sessions = Presence.list_active_sessions()

    # Apply filtering
    filtered_sessions =
      all_sessions
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_type(socket.assigns.filter_type)
      |> sort_sessions(socket.assigns.sort_by, socket.assigns.sort_order)

    # Apply pagination
    total_count = length(filtered_sessions)
    total_pages = div(total_count + @per_page - 1, @per_page)

    page = max(1, min(socket.assigns.page, total_pages))
    offset = (page - 1) * @per_page

    paginated_sessions =
      filtered_sessions
      |> Enum.drop(offset)
      |> Enum.take(@per_page)

    socket
    |> assign(:sessions, paginated_sessions)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:page, page)
  end

  defp load_presence_stats(socket) do
    stats = Presence.get_presence_stats()

    socket
    |> assign(:presence_stats, stats)
  end

  defp filter_by_search(sessions, ""), do: sessions

  defp filter_by_search(sessions, query) do
    query_lower = String.downcase(query)

    Enum.filter(sessions, fn session ->
      (session.ip_address && String.contains?(to_string(session.ip_address), query_lower)) ||
        (session.user_agent && String.contains?(String.downcase(session.user_agent), query_lower)) ||
        (session.current_page && String.contains?(String.downcase(session.current_page), query_lower)) ||
        (session.user_email && String.contains?(String.downcase(session.user_email), query_lower))
    end)
  end

  defp filter_by_type(sessions, "all"), do: sessions
  defp filter_by_type(sessions, "anonymous"), do: Enum.filter(sessions, &(&1.type == :anonymous))
  defp filter_by_type(sessions, "authenticated"), do: Enum.filter(sessions, &(&1.type == :authenticated))

  defp sort_sessions(sessions, :connected_at, order) do
    Enum.sort_by(sessions, & &1.connected_at, {order, DateTime})
  end

  defp sort_sessions(sessions, :type, order) do
    Enum.sort_by(sessions, & &1.type, order)
  end

  defp sort_sessions(sessions, :current_page, order) do
    Enum.sort_by(sessions, &(&1.current_page || ""), order)
  end

  defp sort_sessions(sessions, :user_email, order) do
    Enum.sort_by(sessions, &(&1.user_email || ""), order)
  end

  defp sort_sessions(sessions, field, order) do
    Enum.sort_by(sessions, &(Map.get(&1, field) || ""), order)
  end

  defp toggle_sort_order(:asc), do: :desc
  defp toggle_sort_order(:desc), do: :asc

  defp get_current_path(_socket, _session) do
    "/phoenix_kit/admin/anonymous_sessions"
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_string()
  end

  defp format_time(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  defp format_time(_), do: "Unknown"

  defp connection_duration(connected_at) when is_struct(connected_at, DateTime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, connected_at, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m"
      true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
    end
  end

  defp connection_duration(_), do: "Unknown"

  defp session_type_badge(:anonymous), do: {"badge-info", "Anonymous"}
  defp session_type_badge(:authenticated), do: {"badge-success", "Authenticated"}
  defp session_type_badge(_), do: {"badge-warning", "Unknown"}

  defp sort_icon(current_field, target_field, sort_order) do
    if current_field == target_field do
      case sort_order do
        :asc -> "↑"
        :desc -> "↓"
      end
    else
      "↕"
    end
  end

  defp extract_ip_address(nil), do: "Unknown"
  defp extract_ip_address({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp extract_ip_address(ip) when is_binary(ip), do: ip
  defp extract_ip_address(_), do: "Unknown"

  defp truncate_user_agent(nil), do: "Unknown"
  defp truncate_user_agent(user_agent) when byte_size(user_agent) > 50 do
    String.slice(user_agent, 0, 50) <> "..."
  end
  defp truncate_user_agent(user_agent), do: user_agent

  ## Live Event Handlers for Presence

  def handle_info({:anonymous_session_connected, _session_id, _session_info}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_presence_stats()

    {:noreply, socket}
  end

  def handle_info({:anonymous_session_disconnected, _session_id}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_presence_stats()

    {:noreply, socket}
  end

  def handle_info({:user_session_connected, _user_id, _session_info}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_presence_stats()

    {:noreply, socket}
  end

  def handle_info({:user_session_disconnected, _user_id, _session_id}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_presence_stats()

    {:noreply, socket}
  end

  def handle_info({:presence_stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:presence_stats, stats)

    {:noreply, socket}
  end
end