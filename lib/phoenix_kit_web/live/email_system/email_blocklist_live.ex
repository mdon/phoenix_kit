defmodule PhoenixKitWeb.Live.EmailSystem.EmailBlocklistLive do
  @moduledoc """
  LiveView for managing email blocklist and blocked addresses.

  Provides comprehensive management of blocked email addresses, including:

  - **Blocklist Viewing**: List all blocked email addresses with filtering
  - **Block Management**: Add/remove email addresses from blocklist
  - **Bulk Operations**: Import/export blocklists, bulk add/remove
  - **Temporary Blocks**: Set expiration dates for temporary blocks
  - **Block Reasons**: Categorize blocks by reason (spam, bounce, manual, etc.)
  - **Search & Filter**: Find blocked addresses by email, reason, or date

  ## Features

  - **Real-time Updates**: Live updates when blocks are added/removed
  - **CSV Import/Export**: Bulk management through CSV files
  - **Automatic Blocking**: Integration with rate limiter for auto-blocks
  - **Audit Trail**: Track who blocked addresses and when
  - **Expiration Management**: Automatic cleanup of expired blocks
  - **Statistics**: Analytics on blocked addresses and reasons

  ## Route

  This LiveView is mounted at `{prefix}/admin/emails/blocklist` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-blocklist", PhoenixKitWeb.Live.EmailSystem.EmailBlocklistLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailSystem
  alias PhoenixKit.EmailSystem.RateLimiter
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 30 seconds
  @refresh_interval 30_000

  # Items per page for pagination
  @per_page 50

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Check if email system is enabled
    if EmailSystem.enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh
      if connected?(socket) do
        Process.send_after(self(), :refresh_blocklist, @refresh_interval)
      end

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/emails/blocklist"))
        |> assign(:loading, true)
        |> assign(:blocked_emails, [])
        |> assign(:total_blocked, 0)
        |> assign(:page, 1)
        |> assign(:per_page, @per_page)
        |> assign(:search_term, "")
        |> assign(:reason_filter, "")
        |> assign(:status_filter, "all")
        |> assign(:selected_emails, [])
        |> assign(:show_add_form, false)
        |> assign(:show_import_form, false)
        |> assign(:bulk_action, nil)
        |> assign(:last_updated, DateTime.utc_now())
        |> assign(:statistics, %{})
        |> load_blocklist_data()

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
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    {:noreply,
     socket
     |> assign(:search_term, search_term)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("filter_reason", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:reason_filter, reason)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    case Integer.parse(page) do
      {page_num, _} when page_num > 0 ->
        {:noreply,
         socket
         |> assign(:page, page_num)
         |> load_blocklist_data()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)}
  end

  @impl true
  def handle_event("toggle_import_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_form, !socket.assigns.show_import_form)}
  end

  @impl true
  def handle_event("add_block", params, socket) do
    %{
      "email" => email,
      "reason" => reason,
      "expires_at" => expires_at
    } = params

    opts = []

    opts =
      if expires_at && expires_at != "" do
        case Date.from_iso8601(expires_at) do
          {:ok, date} ->
            expires_datetime = DateTime.new!(date, ~T[23:59:59])
            [expires_at: expires_datetime] ++ opts

          _ ->
            opts
        end
      else
        opts
      end

    case RateLimiter.add_to_blocklist(email, reason, opts) do
      :ok ->
        {:noreply,
         socket
         |> assign(:show_add_form, false)
         |> put_flash(:info, "Email address blocked successfully")
         |> load_blocklist_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to block email: #{reason}")}
    end
  end

  @impl true
  def handle_event("remove_block", %{"email" => email}, socket) do
    RateLimiter.remove_from_blocklist(email)

    {:noreply,
     socket
     |> put_flash(:info, "Email address unblocked successfully")
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("toggle_email_selection", %{"email" => email}, socket) do
    selected = socket.assigns.selected_emails

    new_selected =
      if email in selected do
        List.delete(selected, email)
      else
        [email | selected]
      end

    {:noreply,
     socket
     |> assign(:selected_emails, new_selected)}
  end

  @impl true
  def handle_event("select_all_visible", _params, socket) do
    all_emails = Enum.map(socket.assigns.blocked_emails, & &1.email)

    {:noreply,
     socket
     |> assign(:selected_emails, all_emails)}
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
      "remove" ->
        execute_bulk_remove(socket)

      "export" ->
        execute_bulk_export(socket)

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid bulk action")}
    end
  end

  @impl true
  def handle_event("export_blocklist", %{"format" => format}, socket) do
    case format do
      "csv" ->
        csv_content = export_blocklist_csv(socket.assigns.blocked_emails)
        filename = "email_blocklist_#{Date.utc_today()}.csv"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: csv_content,
           mime_type: "text/csv"
         })}

      "json" ->
        json_content = Jason.encode!(socket.assigns.blocked_emails, pretty: true)
        filename = "email_blocklist_#{Date.utc_today()}.json"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: json_content,
           mime_type: "application/json"
         })}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unsupported export format")}
    end
  end

  @impl true
  def handle_event("import_csv", %{"csv_content" => csv_content}, socket) do
    case import_blocklist_csv(csv_content) do
      {:ok, imported_count} ->
        {:noreply,
         socket
         |> assign(:show_import_form, false)
         |> put_flash(:info, "Successfully imported #{imported_count} blocked emails")
         |> load_blocklist_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Import failed: #{reason}")}
    end
  end

  @impl true
  def handle_info(:refresh_blocklist, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_blocklist, @refresh_interval)

    {:noreply,
     socket
     |> assign(:last_updated, DateTime.utc_now())
     |> load_blocklist_data()}
  end

  defp load_blocklist_data(socket) do
    filters = build_filters(socket.assigns)

    # Load blocked emails using RateLimiter API
    blocked_emails = load_blocked_emails(filters)
    total_blocked = count_blocked_emails(filters)
    statistics = load_blocklist_statistics()

    socket
    |> assign(:blocked_emails, blocked_emails)
    |> assign(:total_blocked, total_blocked)
    |> assign(:statistics, statistics)
    |> assign(:loading, false)
  end

  defp build_filters(assigns) do
    opts = %{}

    opts =
      if assigns.search_term && assigns.search_term != "" do
        Map.put(opts, :search, assigns.search_term)
      else
        opts
      end

    opts =
      if assigns.reason_filter && assigns.reason_filter != "" do
        Map.put(opts, :reason, assigns.reason_filter)
      else
        opts
      end

    opts =
      if assigns.status_filter == "expired" do
        Map.put(opts, :include_expired, true)
      else
        opts
      end

    # Pagination
    offset = (assigns.page - 1) * assigns.per_page

    opts
    |> Map.put(:limit, assigns.per_page)
    |> Map.put(:offset, offset)
    |> Map.put(:order_by, :inserted_at)
    |> Map.put(:order_dir, :desc)
  end

  defp load_blocked_emails(filters) do
    RateLimiter.list_blocklist(filters)
  end

  defp count_blocked_emails(filters) do
    # Remove pagination params for count
    filters
    |> Map.delete(:limit)
    |> Map.delete(:offset)
    |> RateLimiter.count_blocklist()
  end

  defp load_blocklist_statistics do
    RateLimiter.get_blocklist_stats()
  end

  defp execute_bulk_remove(socket) do
    selected_emails = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_emails, 0, fn email, acc ->
        RateLimiter.remove_from_blocklist(email)
        acc + 1
      end)

    message = "Removed #{success_count} of #{length(selected_emails)} emails from blocklist"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_blocklist_data()}
  end

  defp execute_bulk_export(socket) do
    selected_emails = socket.assigns.selected_emails
    blocked_data = Enum.filter(socket.assigns.blocked_emails, &(&1.email in selected_emails))

    csv_content = export_blocklist_csv(blocked_data)
    filename = "selected_blocklist_#{Date.utc_today()}.csv"

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: csv_content,
       mime_type: "text/csv"
     })}
  end

  defp export_blocklist_csv(blocked_emails) do
    headers = "email,reason,added_at,expires_at\n"

    rows =
      Enum.map_join(blocked_emails, "\n", fn blocked ->
        expires_str =
          if blocked.expires_at,
            do: Date.to_iso8601(DateTime.to_date(blocked.expires_at)),
            else: ""

        "#{blocked.email},#{blocked.reason},#{Date.to_iso8601(DateTime.to_date(blocked.inserted_at))},#{expires_str}"
      end)

    headers <> rows
  end

  defp import_blocklist_csv(csv_content) do
    lines =
      String.split(csv_content, "\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    # Skip header line if it looks like headers
    lines =
      case List.first(lines) do
        "email,reason" <> _ -> List.delete_at(lines, 0)
        _ -> lines
      end

    imported_count =
      Enum.reduce(lines, 0, fn line, acc ->
        case parse_csv_line(line) do
          {:ok, email, reason, expires_at} ->
            opts = if expires_at, do: [expires_at: expires_at], else: []

            case RateLimiter.add_to_blocklist(email, reason, opts) do
              :ok -> acc + 1
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    {:ok, imported_count}
  rescue
    _ -> {:error, "Invalid CSV format"}
  end

  defp parse_csv_line(line) do
    parts = String.split(line, ",") |> Enum.map(&String.trim/1)

    case parts do
      [email, reason] ->
        {:ok, email, reason, nil}

      [email, reason, ""] ->
        {:ok, email, reason, nil}

      [email, reason, expires_str] ->
        case Date.from_iso8601(expires_str) do
          {:ok, date} -> {:ok, email, reason, DateTime.new!(date, ~T[23:59:59])}
          _ -> {:ok, email, reason, nil}
        end

      _ ->
        {:error, "Invalid line format"}
    end
  end

  defp pagination_range(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    Enum.to_list(start_page..end_page)
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    # Calculate pagination
    total_pages = ceil(assigns.total_blocked / assigns.per_page)
    assigns = assign(assigns, :total_pages, total_pages)

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Blocklist"
      current_path={@url_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button --%>
          <.link
            navigate={Routes.path("/admin/emails")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Emails
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Email Blocklist</h1>
            <p class="text-lg text-base-content">Manage blocked email addresses</p>
          </div>
        </header>

        <%!-- Statistics Cards --%>
        <div class="stats shadow mb-6 w-full">
          <div class="stat">
            <div class="stat-figure text-error">
              <.icon name="hero-no-symbol" class="w-8 h-8" />
            </div>
            <div class="stat-title">Total Blocks</div>
            <div class="stat-value text-error">{@statistics[:total_blocks] || 0}</div>
            <div class="stat-desc">All blocked email addresses</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-warning">
              <.icon name="hero-shield-exclamation" class="w-8 h-8" />
            </div>
            <div class="stat-title">Active Blocks</div>
            <div class="stat-value text-warning">{@statistics[:active_blocks] || 0}</div>
            <div class="stat-desc">Currently enforced blocks</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-info">
              <.icon name="hero-clock" class="w-8 h-8" />
            </div>
            <div class="stat-title">Expired Today</div>
            <div class="stat-value text-info">{@statistics[:expired_today] || 0}</div>
            <div class="stat-desc">Blocks that expired today</div>
          </div>
        </div>

        <%!-- Action Bar --%>
        <div class="flex flex-wrap justify-between items-center gap-4 mb-6">
          <%!-- Search & Filters --%>
          <div class="flex flex-wrap gap-2">
            <%!-- Search --%>
            <form phx-submit="search" class="flex gap-2">
              <input
                type="text"
                name="search"
                value={@search_term}
                placeholder="Search email..."
                class="input input-bordered input-sm"
              />
              <button type="submit" class="btn btn-sm btn-primary">
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
            </form>

            <%!-- Reason Filter --%>
            <select
              phx-change="filter_reason"
              name="reason"
              class="select select-bordered select-sm"
            >
              <option value="">All Reasons</option>
              <%= for {reason, _count} <- Map.to_list(@statistics[:by_reason] || %{}) do %>
                <option value={reason} selected={@reason_filter == reason}>
                  {String.capitalize(String.replace(reason, "_", " "))}
                </option>
              <% end %>
            </select>

            <%!-- Status Filter --%>
            <select
              phx-change="filter_status"
              name="status"
              class="select select-bordered select-sm"
            >
              <option value="all" selected={@status_filter == "all"}>Active Only</option>
              <option value="expired" selected={@status_filter == "expired"}>Include Expired</option>
            </select>
          </div>

          <%!-- Action Buttons --%>
          <div class="flex gap-2">
            <button phx-click="toggle_add_form" class="btn btn-sm btn-success">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Block
            </button>
            <button phx-click="toggle_import_form" class="btn btn-sm btn-info">
              <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Import CSV
            </button>
            <button phx-click="export_blocklist" phx-value-format="csv" class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-up-tray" class="w-4 h-4 mr-1" /> Export CSV
            </button>
            <button phx-click="refresh" class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-path" class="w-4 h-4" />
            </button>
          </div>
        </div>

        <%!-- Add Block Form Modal --%>
        <%= if @show_add_form do %>
          <div class="card bg-base-100 shadow-sm mb-6">
            <div class="card-body">
              <div class="flex justify-between items-center mb-4">
                <h3 class="card-title">Add Email to Blocklist</h3>
                <button phx-click="toggle_add_form" class="btn btn-sm btn-ghost">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <form phx-submit="add_block" class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Email Address</span>
                  </label>
                  <input
                    type="email"
                    name="email"
                    placeholder="blocked@example.com"
                    class="input input-bordered"
                    required
                  />
                </div>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Reason</span>
                  </label>
                  <select name="reason" class="select select-bordered" required>
                    <option value="manual_block">Manual Block</option>
                    <option value="spam">Spam</option>
                    <option value="bounce_limit">Bounce Limit Exceeded</option>
                    <option value="complaint">Complaint</option>
                    <option value="abuse">Abuse</option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Expires At (Optional)</span>
                  </label>
                  <input type="date" name="expires_at" class="input input-bordered" />
                </div>

                <div class="col-span-full flex justify-end gap-2">
                  <button type="button" phx-click="toggle_add_form" class="btn btn-ghost">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-success">
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add to Blocklist
                  </button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Import CSV Form Modal --%>
        <%= if @show_import_form do %>
          <div class="card bg-base-100 shadow-sm mb-6">
            <div class="card-body">
              <div class="flex justify-between items-center mb-4">
                <h3 class="card-title">Import Blocklist from CSV</h3>
                <button phx-click="toggle_import_form" class="btn btn-sm btn-ghost">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <div class="alert alert-info mb-4">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <div class="text-sm">
                  <p class="font-semibold">CSV Format:</p>
                  <p>email,reason,expires_at (optional)</p>
                  <p class="mt-1 font-mono text-xs">
                    spam@example.com,spam,2025-12-31
                  </p>
                </div>
              </div>

              <form phx-submit="import_csv">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">CSV Content</span>
                  </label>
                  <textarea
                    name="csv_content"
                    class="textarea textarea-bordered font-mono"
                    rows="8"
                    placeholder="email,reason,expires_at&#10;spam@example.com,spam,&#10;abuse@test.com,abuse,2025-12-31"
                    required
                  >
                  </textarea>
                </div>

                <div class="flex justify-end gap-2 mt-4">
                  <button type="button" phx-click="toggle_import_form" class="btn btn-ghost">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-info">
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Import
                  </button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Bulk Actions Bar --%>
        <%= if length(@selected_emails) > 0 do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div class="flex-1">
              <p class="font-semibold">{length(@selected_emails)} email(s) selected</p>
            </div>
            <div class="flex gap-2">
              <%= if @bulk_action do %>
                <span class="text-sm">Confirm: {String.upcase(@bulk_action)}?</span>
                <button phx-click="execute_bulk_action" class="btn btn-sm btn-warning">
                  Confirm
                </button>
                <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
                  Cancel
                </button>
              <% else %>
                <button
                  phx-click="set_bulk_action"
                  phx-value-action="remove"
                  class="btn btn-sm btn-error"
                >
                  Remove Selected
                </button>
                <button
                  phx-click="set_bulk_action"
                  phx-value-action="export"
                  class="btn btn-sm btn-info"
                >
                  Export Selected
                </button>
                <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
                  Clear
                </button>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Blocklist Table --%>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex justify-between items-center mb-4">
              <h2 class="card-title">
                Blocked Emails ({@total_blocked})
              </h2>
              <%= if length(@blocked_emails) > 0 do %>
                <button phx-click="select_all_visible" class="btn btn-xs btn-outline">
                  Select All on Page
                </button>
              <% end %>
            </div>

            <%= if @loading do %>
              <div class="flex justify-center items-center h-32">
                <span class="loading loading-spinner loading-md"></span>
                <span class="ml-2">Loading blocklist...</span>
              </div>
            <% else %>
              <%= if length(@blocked_emails) > 0 do %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th><input type="checkbox" class="checkbox checkbox-sm" disabled /></th>
                        <th>Email Address</th>
                        <th>Reason</th>
                        <th>Added</th>
                        <th>Expires</th>
                        <th>Status</th>
                        <th>Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for blocked <- @blocked_emails do %>
                        <% is_expired =
                          blocked.expires_at &&
                            DateTime.compare(blocked.expires_at, DateTime.utc_now()) == :lt %>
                        <tr class={is_expired && "opacity-50"}>
                          <td>
                            <input
                              type="checkbox"
                              class="checkbox checkbox-sm"
                              checked={blocked.email in @selected_emails}
                              phx-click="toggle_email_selection"
                              phx-value-email={blocked.email}
                            />
                          </td>
                          <td class="font-mono text-xs">{blocked.email}</td>
                          <td>
                            <span class="badge badge-sm badge-outline">
                              {String.replace(blocked.reason, "_", " ")}
                            </span>
                          </td>
                          <td class="text-xs">
                            {UtilsDate.format_date_with_user_format(
                              DateTime.to_date(blocked.inserted_at)
                            )}
                          </td>
                          <td class="text-xs">
                            <%= if blocked.expires_at do %>
                              {UtilsDate.format_date_with_user_format(
                                DateTime.to_date(blocked.expires_at)
                              )}
                            <% else %>
                              <span class="text-base-content/50">Never</span>
                            <% end %>
                          </td>
                          <td>
                            <%= if is_expired do %>
                              <span class="badge badge-xs badge-ghost">Expired</span>
                            <% else %>
                              <span class="badge badge-xs badge-error">Active</span>
                            <% end %>
                          </td>
                          <td>
                            <button
                              phx-click="remove_block"
                              phx-value-email={blocked.email}
                              class="btn btn-xs btn-outline btn-success"
                              title="Remove from blocklist"
                            >
                              <.icon name="hero-check" class="w-3 h-3" /> Unblock
                            </button>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>

                <%!-- Pagination --%>
                <%= if @total_pages > 1 do %>
                  <div class="flex justify-center mt-6">
                    <div class="join">
                      <%= if @page > 1 do %>
                        <button
                          phx-click="change_page"
                          phx-value-page={@page - 1}
                          class="join-item btn btn-sm"
                        >
                          «
                        </button>
                      <% end %>

                      <%= for page_num <- pagination_range(@page, @total_pages) do %>
                        <button
                          phx-click="change_page"
                          phx-value-page={page_num}
                          class={[
                            "join-item btn btn-sm",
                            page_num == @page && "btn-active"
                          ]}
                        >
                          {page_num}
                        </button>
                      <% end %>

                      <%= if @page < @total_pages do %>
                        <button
                          phx-click="change_page"
                          phx-value-page={@page + 1}
                          class="join-item btn btn-sm"
                        >
                          »
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% else %>
                <div class="text-center py-12">
                  <.icon name="hero-shield-check" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <p class="text-lg font-medium text-base-content/70">
                    No blocked emails found
                  </p>
                  <p class="text-sm text-base-content/50 mt-2">
                    <%= if @search_term != "" || @reason_filter != "" do %>
                      Try adjusting your filters
                    <% else %>
                      Your blocklist is empty
                    <% end %>
                  </p>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
