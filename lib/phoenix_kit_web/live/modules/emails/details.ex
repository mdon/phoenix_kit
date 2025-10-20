defmodule PhoenixKitWeb.Live.Modules.Emails.Details do
  @moduledoc """
  LiveView for displaying detailed information about a specific email log.

  Provides comprehensive view of email metadata, delivery status, events timeline,
  and performance analytics for individual emails.

  ## Features

  - **Complete Email Metadata**: Headers, size, attachments, template info
  - **Events Timeline**: Chronological view of all email events
  - **Delivery Status**: Real-time status tracking and updates
  - **Geographic Data**: Location info for opens and clicks
  - **Performance Metrics**: Individual email analytics
  - **Debugging Info**: Technical details for troubleshooting
  - **Related Emails**: Other emails in same campaign/template

  ## Route

  This LiveView is mounted at `{prefix}/admin/emails/:id` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-logs/:id", PhoenixKitWeb.Live.Modules.Emails.EmailDetailsLive, :show

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Emails
  alias PhoenixKit.Emails.Log
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Check if email is enabled
    if Emails.enabled?() do
      case Integer.parse(id) do
        {email_id, _} ->
          # Get project title from settings
          project_title = Settings.get_setting("project_title", "PhoenixKit")

          socket =
            socket
            |> assign(:email_id, email_id)
            |> assign(:project_title, project_title)
            |> assign(:email_log, nil)
            |> assign(:events, [])
            |> assign(:related_emails, [])
            |> assign(:loading, true)
            |> assign(:syncing, false)
            |> load_email_data()

          {:ok, socket}

        _ ->
          {:ok,
           socket
           |> put_flash(:error, "Invalid email ID")
           |> push_navigate(to: Routes.path("/admin/emails"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Email is not enabled")
       |> push_navigate(to: Routes.path("/admin/emails"))}
    end
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_email_data()}
  end

  @impl true
  def handle_event("sync_status", _params, socket) do
    if socket.assigns.email_log do
      # Determine which message ID to use for sync (prefer AWS message ID)
      {message_id, id_type} =
        if socket.assigns.email_log.aws_message_id do
          {socket.assigns.email_log.aws_message_id, "AWS SES message ID"}
        else
          {socket.assigns.email_log.message_id, "internal message ID"}
        end

      socket = assign(socket, :syncing, true)

      case Emails.sync_email_status(message_id) do
        {:ok, result} ->
          flash_message = build_sync_flash_message(result, id_type)
          flash_type = determine_flash_type(result)

          socket =
            socket
            |> assign(:syncing, false)
            |> put_flash(flash_type, flash_message)
            |> load_email_data()

          {:noreply, socket}

        {:error, reason} ->
          flash_message = build_error_flash_message(reason, message_id, socket, id_type)

          socket =
            socket
            |> assign(:syncing, false)
            |> put_flash(:error, flash_message)

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "❌ Email log not found")}
    end
  end

  @impl true
  def handle_event("toggle_headers", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_headers, !Map.get(socket.assigns, :show_headers, false))}
  end

  @impl true
  def handle_event("toggle_body", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_body, !Map.get(socket.assigns, :show_body, false))}
  end

  @impl true
  def handle_event("view_related", %{"campaign_id" => campaign_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails?campaign_id=#{campaign_id}"))}
  end

  @impl true
  def handle_event("view_related", %{"template_name" => template_name}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails?template_name=#{template_name}"))}
  end

  ## --- Template ---

  ## --- Private Helper Functions ---

  # Load email data and related information
  defp load_email_data(socket) do
    email_id = socket.assigns.email_id

    try do
      email_log = Emails.get_log!(email_id)
      events = Emails.list_events_for_log(email_id)
      related_emails = get_related_emails(email_log)

      socket
      |> assign(:email_log, email_log)
      |> assign(:events, events)
      |> assign(:related_emails, related_emails)
      |> assign(:loading, false)
      |> assign(:show_headers, false)
      |> assign(:show_body, false)
      |> assign(:page_title, "Email ##{email_id}")
    rescue
      Ecto.NoResultsError ->
        socket
        |> assign(:email_log, nil)
        |> assign(:events, [])
        |> assign(:related_emails, [])
        |> assign(:loading, false)

      error ->
        Logger.error("Failed to load email data: #{inspect(error)}")

        socket
        |> assign(:loading, false)
        |> put_flash(:error, "Failed to load email data")
    end
  end

  # Get related emails (same campaign or template)
  defp get_related_emails(%Log{
         campaign_id: campaign_id,
         template_name: template_name,
         id: current_id
       }) do
    filters = %{limit: 10}

    filters =
      cond do
        campaign_id -> Map.put(filters, :campaign_id, campaign_id)
        template_name -> Map.put(filters, :template_name, template_name)
        true -> filters
      end

    Emails.list_logs(filters)
    |> Enum.reject(fn log -> log.id == current_id end)
  end

  defp get_related_emails(_), do: []

  # Helper functions for template
  defp status_badge_class(status, extra_classes \\ "badge-sm") do
    base_class = "badge #{extra_classes}"

    case status do
      "sent" -> "#{base_class} badge-info"
      "delivered" -> "#{base_class} badge-success"
      "bounced" -> "#{base_class} badge-error"
      "opened" -> "#{base_class} badge-primary"
      "clicked" -> "#{base_class} badge-secondary"
      "failed" -> "#{base_class} badge-error"
      _ -> "#{base_class} badge-ghost"
    end
  end

  defp event_marker_class(event_type) do
    base_class = "w-6 h-6 rounded-full flex items-center justify-center text-white"

    case event_type do
      "send" -> "#{base_class} bg-blue-500"
      "delivery" -> "#{base_class} bg-green-500"
      "bounce" -> "#{base_class} bg-red-500"
      "complaint" -> "#{base_class} bg-orange-500"
      "open" -> "#{base_class} bg-purple-500"
      "click" -> "#{base_class} bg-indigo-500"
      _ -> "#{base_class} bg-base-content"
    end
  end

  defp event_icon(event_type) do
    case event_type do
      "send" -> "hero-paper-airplane"
      "delivery" -> "hero-check-circle"
      "bounce" -> "hero-exclamation-triangle"
      "complaint" -> "hero-flag"
      "open" -> "hero-eye"
      "click" -> "hero-cursor-arrow-rays"
      _ -> "hero-clock"
    end
  end

  defp format_event_title(event_type) do
    case event_type do
      "send" -> "Email Sent"
      "delivery" -> "Email Delivered"
      "bounce" -> "Email Bounced"
      "complaint" -> "Spam Complaint"
      "open" -> "Email Opened"
      "click" -> "Link Clicked"
      _ -> String.capitalize(event_type)
    end
  end

  # Render event-specific details
  defp render_event_details(event) do
    case event.event_type do
      "bounce" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <div>Type: <span class="font-medium">{@event.bounce_type || "unknown"}</span></div>
          <%= if get_in(@event.event_data, ["reason"]) do %>
            <div>Reason: {get_in(@event.event_data, ["reason"])}</div>
          <% end %>
        </div>
        """

      "complaint" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <div>Type: <span class="font-medium">{@event.complaint_type || "abuse"}</span></div>
          <%= if get_in(@event.event_data, ["feedback_id"]) do %>
            <div>Feedback ID: {get_in(@event.event_data, ["feedback_id"])}</div>
          <% end %>
        </div>
        """

      "open" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if @event.ip_address do %>
            <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
          <% end %>
          <%= if get_in(@event.geo_location, ["country"]) do %>
            <div>Location: {get_in(@event.geo_location, ["country"])}</div>
          <% end %>
        </div>
        """

      "click" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if @event.link_url do %>
            <div class="mb-1">
              Link:
              <a href={@event.link_url} target="_blank" class="text-blue-600 hover:underline break-all">
                {String.slice(@event.link_url, 0, 50)}{if String.length(@event.link_url) > 50, do: "..."}
              </a>
            </div>
          <% end %>
          <%= if @event.ip_address do %>
            <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
          <% end %>
        </div>
        """

      "delivery" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if get_in(@event.event_data, ["processingTimeMillis"]) do %>
            <div>
              Processing time:
              <span class="font-medium">{get_in(@event.event_data, ["processingTimeMillis"])} ms</span>
            </div>
          <% end %>
          <%= if get_in(@event.event_data, ["smtpResponse"]) do %>
            <div>
              SMTP:
              <span class="font-mono text-success">{get_in(@event.event_data, ["smtpResponse"])}</span>
            </div>
          <% end %>
          <%= if get_in(@event.event_data, ["reportingMTA"]) do %>
            <div>
              Server: <span class="font-mono">{get_in(@event.event_data, ["reportingMTA"])}</span>
            </div>
          <% end %>
        </div>
        """

      "send" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if @event.aws_message_id do %>
            <div>
              AWS Message ID:
              <span class="font-mono text-xs break-all">
                {String.slice(@event.aws_message_id, 0, 40)}{if String.length(@event.aws_message_id) > 40,
                  do: "..."}
              </span>
            </div>
          <% end %>
        </div>
        """

      _ ->
        assigns = %{event: event}

        ~H"""
        <%= if map_size(@event.event_data) > 0 do %>
          <div class="text-xs text-base-content/60">
            Additional data available
          </div>
        <% end %>
        """
    end
  end

  defp format_bytes(nil), do: "Unknown"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  defp format_duration(start_time, end_time) do
    diff_seconds = DateTime.diff(end_time, start_time, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m #{rem(diff_seconds, 60)}s"
      true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
    end
  end

  # Build event details list for success message
  defp build_event_details(sqs_events, dlq_events, events_failed) do
    details = []

    details =
      if sqs_events > 0, do: ["#{sqs_events} from SQS" | details], else: details

    details =
      if dlq_events > 0, do: ["#{dlq_events} from DLQ" | details], else: details

    if events_failed > 0, do: ["#{events_failed} failed" | details], else: details
  end

  # Build success flash message
  defp build_sync_flash_message(result, id_type) do
    events_processed = Map.get(result, :events_processed, 0)
    total_events_found = Map.get(result, :total_events_found, 0)
    sqs_events = Map.get(result, :sqs_events_found, 0)
    dlq_events = Map.get(result, :dlq_events_found, 0)
    events_failed = Map.get(result, :events_failed, 0)
    existing_log_found = Map.get(result, :existing_log_found, false)
    log_updated = Map.get(result, :log_updated, false)
    message = Map.get(result, :message, nil)

    cond do
      total_events_found > 0 and events_processed > 0 ->
        details = build_event_details(sqs_events, dlq_events, events_failed)
        source_info = if length(details) > 0, do: " (#{Enum.join(details, ", ")})", else: ""
        status_info = if log_updated, do: " - Email status updated", else: ""

        "✅ Processed #{events_processed}/#{total_events_found} events#{source_info}#{status_info} using #{id_type}"

      total_events_found > 0 and events_processed == 0 ->
        "⚠️ Found #{total_events_found} events but none could be processed successfully using #{id_type}"

      not existing_log_found ->
        "ℹ️ No email log found in database for #{id_type}. Events may be for a different email."

      true ->
        search_info = " (searched using #{id_type})"
        (message || "No new events found in SQS or DLQ queues") <> search_info
    end
  end

  # Determine flash type based on sync results
  defp determine_flash_type(result) do
    events_processed = Map.get(result, :events_processed, 0)
    total_events_found = Map.get(result, :total_events_found, 0)
    existing_log_found = Map.get(result, :existing_log_found, false)

    cond do
      events_processed > 0 -> :info
      total_events_found > 0 and events_processed == 0 -> :warning
      not existing_log_found -> :warning
      true -> :info
    end
  end

  # Build ID info string for error messages
  defp build_id_info(message_id, email_log, id_type) do
    if message_id == email_log.message_id do
      " (using #{id_type})"
    else
      " (using #{id_type}: #{String.slice(message_id, 0, 20)}...)"
    end
  end

  # Build error flash message
  defp build_error_flash_message(reason, message_id, socket, id_type) do
    case reason do
      "AWS credentials not configured. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables." ->
        "❌ AWS credentials not configured. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."

      "Email is disabled. Please enable it in settings." ->
        "❌ Email is disabled. Please enable it in admin settings."

      reason ->
        id_info = build_id_info(message_id, socket.assigns.email_log, id_type)
        "❌ Sync failed: #{reason}#{id_info}"
    end
  end
end
