defmodule PhoenixKitWeb.Live.Modules.UnderConstruction.Settings do
  @moduledoc """
  Settings page for the Under Construction (Maintenance Mode) module.

  Allows admins to customize the maintenance page header and subtext.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.UnderConstruction

  def mount(_params, _session, socket) do
    # Get current settings
    config = UnderConstruction.get_config()

    socket =
      socket
      |> assign(:page_title, "Maintenance Mode Settings")
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> assign(:enabled, config.enabled)
      |> assign(:saved, false)

    {:ok, socket}
  end

  def handle_event("update_header", %{"header" => header}, socket) do
    {:noreply, assign(socket, :header, header)}
  end

  def handle_event("update_subtext", %{"subtext" => subtext}, socket) do
    {:noreply, assign(socket, :subtext, subtext)}
  end

  def handle_event("save", _params, socket) do
    # Save header and subtext to database
    UnderConstruction.update_header(socket.assigns.header)
    UnderConstruction.update_subtext(socket.assigns.subtext)

    socket =
      socket
      |> assign(:saved, true)
      |> put_flash(:info, "Maintenance mode settings saved successfully")

    # Reset saved flag after 2 seconds
    Process.send_after(self(), :reset_saved, 2000)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    # Reload settings from database
    config = UnderConstruction.get_config()

    socket =
      socket
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> put_flash(:info, "Changes discarded")

    {:noreply, socket}
  end

  def handle_info(:reset_saved, socket) do
    {:noreply, assign(socket, :saved, false)}
  end
end
