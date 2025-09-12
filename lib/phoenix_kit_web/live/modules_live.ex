defmodule PhoenixKitWeb.Live.ModulesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()
    email_tracking_config = EmailTracking.get_config()

    socket =
      socket
      |> assign(:current_path, current_path)
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

  def handle_event("toggle_referral_codes_required", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_required = !socket.assigns.referral_codes_required

    result = ReferralCodes.set_required(new_required)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_required, new_required)
          |> put_flash(
            :info,
            if(new_required,
              do: "Referral codes are now required",
              else: "Referral codes are now optional"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes requirement setting")
        {:noreply, socket}
    end
  end

  def handle_event("update_max_uses_per_code", %{"max_uses_per_code" => value}, socket) do
    case Integer.parse(value) do
      {max_uses, _} when max_uses > 0 and max_uses <= 10_000 ->
        case ReferralCodes.set_max_uses_per_code(max_uses) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:max_uses_per_code, max_uses)
              |> put_flash(:info, "Maximum uses per code updated to #{max_uses}")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update maximum uses per code")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 10,000")
        {:noreply, socket}
    end
  end

  def handle_event("update_max_codes_per_user", %{"max_codes_per_user" => value}, socket) do
    case Integer.parse(value) do
      {max_codes, _} when max_codes > 0 and max_codes <= 1000 ->
        case ReferralCodes.set_max_codes_per_user(max_codes) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:max_codes_per_user, max_codes)
              |> put_flash(:info, "Maximum codes per user updated to #{max_codes}")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update maximum codes per user")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 1,000")
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

  def handle_event("toggle_email_tracking_save_body", _params, socket) do
    # Toggle email body saving
    new_save_body = !socket.assigns.email_tracking_save_body

    result = EmailTracking.set_save_body(new_save_body)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_tracking_save_body, new_save_body)
          |> put_flash(
            :info,
            if(new_save_body,
              do: "Email body saving enabled",
              else: "Email body saving disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email body saving setting")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_tracking_ses_events", _params, socket) do
    # Toggle AWS SES events tracking
    new_ses_events = !socket.assigns.email_tracking_ses_events

    result = EmailTracking.set_ses_events(new_ses_events)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_tracking_ses_events, new_ses_events)
          |> put_flash(
            :info,
            if(new_ses_events,
              do: "AWS SES events tracking enabled",
              else: "AWS SES events tracking disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update AWS SES events tracking")
        {:noreply, socket}
    end
  end

  def handle_event("update_email_tracking_retention", %{"retention_days" => value}, socket) do
    case Integer.parse(value) do
      {retention_days, _} when retention_days > 0 and retention_days <= 365 ->
        case EmailTracking.set_retention_days(retention_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_tracking_retention_days, retention_days)
              |> put_flash(:info, "Email retention period updated to #{retention_days} days")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update email retention period")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 365")
        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For ModulesLive, always return modules path
    Routes.path("/admin/modules")
  end
end
