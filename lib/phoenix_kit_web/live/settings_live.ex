defmodule PhoenixKitWeb.Live.SettingsLive do
  use PhoenixKitWeb, :live_view

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Settings")

    {:ok, socket}
  end

  defp get_current_path(_socket, _session) do
    # For SettingsLive, always return settings path
    "/phoenix_kit/admin/settings"
  end
end