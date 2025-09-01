defmodule PhoenixKitWeb.Live.ModulesLive do
  use PhoenixKitWeb, :live_view

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Modules")

    {:ok, socket}
  end

  defp get_current_path(_socket, _session) do
    # For ModulesLive, always return modules path
    "/phoenix_kit/admin/modules"
  end
end