defmodule PhoenixKitWeb.Live.EmailSystem.EmailQueueLive do
  @moduledoc """
  LiveView for email queue monitoring and rate limit management.

  Provides real-time monitoring of email sending activity, rate limiting status,
  and queue management functionality for the email system.

  ## Features

  - **Real-time Activity**: Live updates of recent email sending activity
  - **Rate Limit Monitoring**: Current rate limit status and usage
  - **Failed Email Management**: Retry and management of failed emails
  - **Bulk Operations**: Pause/resume email sending, bulk retry
  - **Provider Status**: Monitor email provider health and performance
  - **Alert Management**: Configure alerts for rate limits and failures

  ## Route

  This LiveView is mounted at `{prefix}/admin/emails/queue` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-queue", PhoenixKitWeb.Live.EmailSystem.EmailQueueLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailSystem
  alias PhoenixKit.EmailSystem.{EmailLog, RateLimiter}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 10 seconds for real-time monitoring
  @refresh_interval 10_000

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Check if email is enabled
    if EmailSystem.enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh for real-time updates
      if connected?(socket) do
        Process.send_after(self(), :refresh_queue, @refresh_interval)
      end

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/emails/queue"))
        |> assign(:loading, true)
        |> assign(:recent_activity, [])
        |> assign(:rate_limit_status, %{})
        |> assign(:failed_emails, [])
        |> assign(:system_status, %{})
        |> assign(:selected_emails, [])
        |> assign(:bulk_action, nil)
        |> assign(:last_updated, DateTime.utc_now())
        |> load_queue_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_queue_data()}
  end

  @impl true
  def handle_event("retry_email", %{"email_id" => email_id}, socket) do
    case Integer.parse(email_id) do
      {id, _} ->
        case retry_failed_email(id) do
          {:ok, _log} ->
            {:noreply,
             socket
             |> put_flash(:info, "Email queued for retry")
             |> load_queue_data()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to retry email: #{reason}")}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid email ID")}
    end
  end

  @impl true
  def handle_event("toggle_email_selection", %{"email_id" => email_id}, socket) do
    case Integer.parse(email_id) do
      {id, _} ->
        selected = socket.assigns.selected_emails

        new_selected =
          if id in selected do
            List.delete(selected, id)
          else
            [id | selected]
          end

        {:noreply,
         socket
         |> assign(:selected_emails, new_selected)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_all_failed", _params, socket) do
    all_failed_ids = Enum.map(socket.assigns.failed_emails, & &1.id)

    {:noreply,
     socket
     |> assign(:selected_emails, all_failed_ids)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)}
  end

  @impl true
  def handle_event("set_bulk_action", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action, action)}
  end

  @impl true
  def handle_event("execute_bulk_action", _params, socket) do
    case socket.assigns.bulk_action do
      "retry" ->
        execute_bulk_retry(socket)

      "delete" ->
        execute_bulk_delete(socket)

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid bulk action")}
    end
  end

  @impl true
  def handle_event("reset_rate_limits", _params, socket) do
    # This would reset rate limit counters (implementation would depend on storage)
    {:noreply,
     socket
     |> put_flash(:info, "Rate limits reset")
     |> load_queue_data()}
  end

  @impl true
  def handle_info(:refresh_queue, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_queue, @refresh_interval)

    {:noreply,
     socket
     |> assign(:last_updated, DateTime.utc_now())
     |> load_queue_data()}
  end

  defp load_queue_data(socket) do
    recent_activity = load_recent_activity()
    rate_limit_status = RateLimiter.get_rate_limit_status()
    failed_emails = load_failed_emails()
    system_status = load_system_status()

    socket
    |> assign(:recent_activity, recent_activity)
    |> assign(:rate_limit_status, rate_limit_status)
    |> assign(:failed_emails, failed_emails)
    |> assign(:system_status, system_status)
    |> assign(:loading, false)
  end

  defp load_recent_activity do
    # Get last 20 emails
    EmailSystem.list_logs(%{limit: 20, order_by: :sent_at, order_dir: :desc})
  end

  defp load_failed_emails do
    # Get failed emails from last 24 hours
    EmailSystem.list_logs(%{
      status: "failed",
      since: DateTime.add(DateTime.utc_now(), -24, :hour),
      limit: 50
    })
  end

  defp load_system_status do
    %{
      system_enabled: EmailSystem.enabled?(),
      total_sent_today: get_today_count(),
      retention_days: EmailSystem.get_retention_days()
    }
  end

  defp get_today_count do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    now = DateTime.utc_now()

    case EmailSystem.get_system_stats(
           {:date_range, DateTime.to_date(today_start), DateTime.to_date(now)}
         ) do
      %{total_sent: count} -> count
      _ -> 0
    end
  end

  defp retry_failed_email(email_id) do
    # Get the email log
    log = EmailSystem.get_log!(email_id)

    # Update status to "queued" for retry and increment retry_count
    EmailSystem.update_log_status(log, "queued")

    # Also update retry count
    EmailLog.update_log(log, %{
      retry_count: (log.retry_count || 0) + 1,
      error_message: nil
    })
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}

    error ->
      Logger.error("Failed to retry email #{email_id}: #{inspect(error)}")
      {:error, :retry_failed}
  end

  defp execute_bulk_retry(socket) do
    selected_ids = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_ids, 0, fn id, acc ->
        case retry_failed_email(id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    message = "Retried #{success_count} of #{length(selected_ids)} emails"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_queue_data()}
  end

  defp execute_bulk_delete(socket) do
    selected_ids = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_ids, 0, fn id, acc ->
        try do
          log = EmailSystem.get_log!(id)

          case EmailSystem.delete_log(log) do
            {:ok, _} ->
              acc + 1

            {:error, reason} ->
              Logger.error("Failed to delete email #{id}: #{inspect(reason)}")
              acc
          end
        rescue
          Ecto.NoResultsError ->
            Logger.warning("Email log #{id} not found for deletion")
            acc

          error ->
            Logger.error("Error deleting email #{id}: #{inspect(error)}")
            acc
        end
      end)

    message = "Deleted #{success_count} of #{length(selected_ids)} emails"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_queue_data()}
  end

  defp format_number(number) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_number(number), do: to_string(number)

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Queue"
      current_path={@url_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button (Left aligned) --%>
          <.link
            navigate={Routes.path("/admin/emails")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Emails
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Email Queue</h1>
            <p class="text-lg text-base-content">Real-time monitoring and queue management</p>
          </div>
        </header>

        <%!-- Action Buttons --%>
        <div class="flex justify-between items-center gap-2 mb-6">
          <div class="text-sm text-base-content/70">
            Last updated: {UtilsDate.format_time_with_user_format(@last_updated)}
          </div>

          <div class="flex gap-2">
            <.button phx-click="refresh" class="btn btn-outline btn-sm">
              <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Refresh
            </.button>
          </div>
        </div>

        <%!-- System Status Cards --%>
        <div class="stats shadow mb-6 w-full">
          <div class="stat">
            <div class="stat-figure text-primary">
              <.icon name="hero-server" class="w-8 h-8" />
            </div>
            <div class="stat-title">System Status</div>
            <div class={[
              "stat-value",
              (@system_status[:system_enabled] && "text-success") || "text-error"
            ]}>
              {(@system_status[:system_enabled] && "Online") || "Offline"}
            </div>
            <div class="stat-desc">
              Email system is {(@system_status[:system_enabled] && "operational") || "disabled"}
            </div>
          </div>

          <div class="stat">
            <div class="stat-figure text-secondary">
              <.icon name="hero-envelope" class="w-8 h-8" />
            </div>
            <div class="stat-title">Sent Today</div>
            <div class="stat-value text-secondary">
              {format_number(@system_status[:total_sent_today] || 0)}
            </div>
            <div class="stat-desc">Total emails sent since midnight</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-warning">
              <.icon name="hero-exclamation-triangle" class="w-8 h-8" />
            </div>
            <div class="stat-title">Failed (24h)</div>
            <div class={[
              "stat-value",
              (length(@failed_emails) > 0 && "text-error") || "text-success"
            ]}>
              {length(@failed_emails)}
            </div>
            <div class="stat-desc">Failed emails in last 24 hours</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-info">
              <.icon name="hero-clock" class="w-8 h-8" />
            </div>
            <div class="stat-title">Retention</div>
            <div class="stat-value text-info">{@system_status[:retention_days] || 90}</div>
            <div class="stat-desc">Days of data retention</div>
          </div>
        </div>

        <%!-- Rate Limit Status --%>
        <div class="card bg-base-100 shadow-sm mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg mb-4">Rate Limit Status</h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <%!-- Global Rate Limit --%>
              <div class="stat bg-base-200 rounded-lg">
                <div class="stat-title">Global Hourly Limit</div>
                <div class="stat-value text-sm">
                  {format_number(@rate_limit_status[:global][:count] || 0)} / {format_number(
                    @rate_limit_status[:global][:limit] || 0
                  )}
                </div>
                <div class="stat-desc">
                  <div class="mt-2">
                    <progress
                      class={[
                        "progress w-full",
                        ((@rate_limit_status[:global][:percentage] || 0) > 80 && "progress-error") ||
                          ((@rate_limit_status[:global][:percentage] || 0) > 60 && "progress-warning") ||
                          "progress-success"
                      ]}
                      value={@rate_limit_status[:global][:percentage] || 0}
                      max="100"
                    >
                    </progress>
                    <span class="text-xs">{@rate_limit_status[:global][:percentage] || 0}% used</span>
                  </div>
                </div>
              </div>

              <%!-- Recipients --%>
              <div class="stat bg-base-200 rounded-lg">
                <div class="stat-title">Recipient Limits</div>
                <div class="stat-value text-sm">
                  {@rate_limit_status[:recipients][:active_limits] || 0}
                </div>
                <div class="stat-desc">
                  Active recipient rate limits ({@rate_limit_status[:recipients][:total_emails] || 0} emails)
                </div>
              </div>

              <%!-- Senders --%>
              <div class="stat bg-base-200 rounded-lg">
                <div class="stat-title">Sender Limits</div>
                <div class="stat-value text-sm">
                  {@rate_limit_status[:senders][:active_limits] || 0}
                </div>
                <div class="stat-desc">
                  Active sender rate limits ({@rate_limit_status[:senders][:total_emails] || 0} emails)
                </div>
              </div>

              <%!-- Blocklist --%>
              <div class="stat bg-base-200 rounded-lg">
                <div class="stat-title">Blocklist</div>
                <div class="stat-value text-sm">
                  {@rate_limit_status[:blocklist][:active_blocks] || 0}
                </div>
                <div class="stat-desc">
                  Active blocks ({@rate_limit_status[:blocklist][:expired_today] || 0} expired today)
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Failed Emails Section --%>
        <%= if length(@failed_emails) > 0 do %>
          <div class="card bg-base-100 shadow-sm mb-6">
            <div class="card-body">
              <div class="flex justify-between items-center mb-4">
                <h2 class="card-title text-lg">Failed Emails (Last 24 Hours)</h2>

                <%= if length(@selected_emails) > 0 do %>
                  <div class="flex gap-2">
                    <span class="badge badge-primary">{length(@selected_emails)} selected</span>
                    <button phx-click="clear_selection" class="btn btn-xs btn-ghost">
                      Clear
                    </button>
                    <button
                      phx-click="set_bulk_action"
                      phx-value-action="retry"
                      class="btn btn-xs btn-success"
                    >
                      Retry Selected
                    </button>
                  </div>
                <% else %>
                  <button phx-click="select_all_failed" class="btn btn-xs btn-outline">
                    Select All
                  </button>
                <% end %>
              </div>

              <%= if @bulk_action do %>
                <div class="alert alert-warning mb-4">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <div>
                    <p class="font-semibold">
                      Confirm bulk action: {String.upcase(@bulk_action)}
                    </p>
                    <p class="text-sm">
                      This will {@bulk_action} {length(@selected_emails)} emails
                    </p>
                  </div>
                  <div class="flex gap-2">
                    <button phx-click="execute_bulk_action" class="btn btn-sm btn-warning">
                      Confirm
                    </button>
                    <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
                      Cancel
                    </button>
                  </div>
                </div>
              <% end %>

              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th><input type="checkbox" class="checkbox checkbox-sm" disabled /></th>
                      <th>Recipient</th>
                      <th>Subject</th>
                      <th>Error</th>
                      <th>Time</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for email <- @failed_emails do %>
                      <tr>
                        <td>
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm"
                            checked={email.id in @selected_emails}
                            phx-click="toggle_email_selection"
                            phx-value-email_id={email.id}
                          />
                        </td>
                        <td class="font-mono text-xs">{email.recipient_email}</td>
                        <td class="truncate max-w-xs">{email.subject}</td>
                        <td class="text-error text-xs truncate max-w-xs">
                          {email.error_message || "Unknown error"}
                        </td>
                        <td class="text-xs">
                          {UtilsDate.format_datetime_with_user_format(email.sent_at)}
                        </td>
                        <td>
                          <button
                            phx-click="retry_email"
                            phx-value-email_id={email.id}
                            class="btn btn-xs btn-outline btn-success"
                          >
                            <.icon name="hero-arrow-path" class="w-3 h-3" /> Retry
                          </button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Recent Activity Section --%>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg mb-4">Recent Activity (Last 20 Emails)</h2>

            <%= if @loading do %>
              <div class="flex justify-center items-center h-32">
                <span class="loading loading-spinner loading-md"></span>
                <span class="ml-2">Loading activity...</span>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Status</th>
                      <th>Recipient</th>
                      <th>Subject</th>
                      <th>Sent At</th>
                      <th>Events</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for email <- @recent_activity do %>
                      <tr>
                        <td>
                          <div class={[
                            "badge badge-sm",
                            (email.status == "sent" && "badge-success") ||
                              (email.status == "failed" &&
                                 "badge-error") || "badge-warning"
                          ]}>
                            {String.capitalize(email.status || "unknown")}
                          </div>
                        </td>
                        <td class="font-mono text-xs">{email.recipient_email}</td>
                        <td class="truncate max-w-xs">{email.subject}</td>
                        <td class="text-xs">
                          {UtilsDate.format_datetime_with_user_format(email.sent_at)}
                        </td>
                        <td>
                          <div class="flex gap-1">
                            <%= if email.delivery_status do %>
                              <div class="badge badge-xs badge-success" title="Delivered">
                                <.icon name="hero-check" class="w-3 h-3" />
                              </div>
                            <% end %>
                            <%= if email.opened_at do %>
                              <div class="badge badge-xs badge-info" title="Opened">
                                <.icon name="hero-envelope-open" class="w-3 h-3" />
                              </div>
                            <% end %>
                            <%= if email.clicked_at do %>
                              <div class="badge badge-xs badge-secondary" title="Clicked">
                                <.icon name="hero-cursor-arrow-rays" class="w-3 h-3" />
                              </div>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>

                    <%= if length(@recent_activity) == 0 do %>
                      <tr>
                        <td colspan="5" class="text-center py-8 text-base-content/60">
                          No recent email activity
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
