defmodule PhoenixKitWeb.Live.ModulesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.ReferralCodes

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:referral_codes_enabled, referral_codes_config.enabled)
      |> assign(:referral_codes_required, referral_codes_config.required)

    {:ok, socket}
  end

  def handle_event("toggle_referral_codes", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_enabled = !socket.assigns.referral_codes_enabled

    result = if new_enabled do
      ReferralCodes.enable_system()
    else
      ReferralCodes.disable_system()
    end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_enabled, new_enabled)
          |> put_flash(:info, if(new_enabled, do: "Referral codes system enabled", else: "Referral codes system disabled"))

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_referral_codes_required", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_required = !socket.assigns.referral_codes_required

    result = ReferralCodes.set_required(new_required)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_required, new_required)
          |> put_flash(:info, if(new_required, do: "Referral codes are now required", else: "Referral codes are now optional"))

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes requirement setting")
        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For ModulesLive, always return modules path
    "/phoenix_kit/admin/modules"
  end
end
