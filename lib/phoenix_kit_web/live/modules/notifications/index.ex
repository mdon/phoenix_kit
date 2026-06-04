defmodule PhoenixKitWeb.Live.Modules.Notifications.Index do
  @moduledoc """
  Simple admin overview for the Notifications module — enabled state,
  retention window, and aggregate counts (total / unread / dismissed).

  Read-only. Enabling/disabling the module lives on the Modules page;
  this page redirects there if the module is disabled.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Notifications
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

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
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :stats, Notifications.admin_stats())}
  end
end
