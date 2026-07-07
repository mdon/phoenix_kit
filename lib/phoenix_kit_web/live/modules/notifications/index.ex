defmodule PhoenixKitWeb.Live.Modules.Notifications.Index do
  @moduledoc """
  Admin overview for the Notifications module — enabled state, retention
  window, aggregate counts (total / unread / dismissed), and a paginated
  list of every notification showing its recipient, what it's about, and
  its per-user seen/dismissed state.

  Read-only. Enabling/disabling the module lives on the Modules page;
  this page redirects there if the module is disabled.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if Notifications.enabled?() do
      socket =
        socket
        |> assign(:page_title, "Notifications")
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:url_path, Routes.path("/admin/notifications"))
        |> assign(:retention_days, Notifications.retention_days())
        |> assign(:stats, Notifications.admin_stats())
        |> assign(:per_page, @per_page)
        |> assign(:page, 1)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         "Notifications module is not enabled. Enable it from the Modules page."
       )
       |> redirect(to: Routes.path("/admin/modules"))}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    # Skip when mount redirected (module disabled) — assigns won't be set up.
    if socket.assigns[:per_page] do
      {:noreply,
       socket
       |> assign(:page, parse_page(params["page"]))
       |> assign(:url_path, URI.parse(url).path)
       |> load_notifications()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:stats, Notifications.admin_stats())
     |> load_notifications()}
  end

  ## Private

  defp load_notifications(socket) do
    {rows, total} =
      Notifications.admin_list(page: socket.assigns.page, per_page: socket.assigns.per_page)

    # Deep-link each recipient to their admin page, via the shared resolver.
    recipient_links =
      rows
      |> Enum.map(&%{resource_type: "user", resource_uuid: &1.recipient_uuid})
      |> PhoenixKit.ResourceLinks.resolve()

    socket
    |> assign(:notifications, rows)
    |> assign(:total, total)
    |> assign(:total_pages, max(ceil(total / socket.assigns.per_page), 1))
    |> assign(:recipient_links, recipient_links)
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> max(n, 1)
      :error -> 1
    end
  end

  # Rendered notification (icon + text) for display, honoring the admin's locale.
  defp render_notification(notification, locale), do: Render.render(notification, locale)

  # Per-user lifecycle state → a badge label + daisyUI class.
  defp status_meta(%{dismissed_at: %DateTime{}}), do: {"Dismissed", "badge-ghost"}
  defp status_meta(%{seen_at: %DateTime{}}), do: {"Seen", "badge-neutral"}
  defp status_meta(_), do: {"Unread", "badge-primary"}

  defp format_datetime(%DateTime{} = dt) do
    "#{UtilsDate.format_date_with_user_format(dt)} #{UtilsDate.format_time_with_user_format(dt)}"
  end

  defp format_datetime(_), do: ""
end
