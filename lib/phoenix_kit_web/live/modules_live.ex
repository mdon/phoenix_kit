defmodule PhoenixKitWeb.Live.ModulesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()
    email_tracking_config = EmailTracking.get_config()

    socket =
      socket
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:referral_codes_enabled, referral_codes_config.enabled)
      |> assign(:referral_codes_required, referral_codes_config.required)
      |> assign(:max_uses_per_code, referral_codes_config.max_uses_per_code)
      |> assign(:max_codes_per_user, referral_codes_config.max_codes_per_user)
      |> assign(:email_tracking_enabled, email_tracking_config.enabled)
      |> assign(:email_tracking_save_body, email_tracking_config.save_body)
      |> assign(:email_tracking_ses_events, email_tracking_config.ses_events)
      |> assign(:email_tracking_retention_days, email_tracking_config.retention_days)

    {:ok, socket}
  end

  def handle_event("toggle_referral_codes", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_enabled = !socket.assigns.referral_codes_enabled

    result =
      if new_enabled do
        ReferralCodes.enable_system()
      else
        ReferralCodes.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Referral codes system enabled",
              else: "Referral codes system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_tracking", _params, socket) do
    # Toggle email tracking system
    new_enabled = !socket.assigns.email_tracking_enabled

    result =
      if new_enabled do
        EmailTracking.enable_system()
      else
        EmailTracking.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_tracking_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Email tracking system enabled",
              else: "Email tracking system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email tracking system")
        {:noreply, socket}
    end
  end
end
