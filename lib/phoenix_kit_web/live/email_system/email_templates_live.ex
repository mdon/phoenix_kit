defmodule PhoenixKitWeb.Live.EmailSystem.EmailTemplatesLive do
  @moduledoc """
  LiveView for displaying and managing email templates in PhoenixKit admin panel.

  Provides comprehensive template management interface with filtering, searching,
  creation, editing, and analytics for email templates.

  ## Features

  - **Real-time Template List**: Live updates of templates
  - **Advanced Filtering**: By category, status, system vs custom
  - **Search Functionality**: Search across template names, descriptions
  - **Template Management**: Create, edit, clone, archive templates
  - **Usage Analytics**: View template usage statistics
  - **Test Send**: Send test emails using templates
  - **System Templates**: Manage core system templates

  ## Route

  This LiveView is mounted at `{prefix}/admin/emails/templates` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-templates", PhoenixKitWeb.Live.EmailSystem.EmailTemplatesLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.EmailSystem.EmailTemplate
  alias PhoenixKit.EmailSystem.Templates
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  @default_per_page 25
  @max_per_page 100

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:page_title, "Email Templates")
      |> assign(:project_title, project_title)
      |> assign(:templates, [])
      |> assign(:total_count, 0)
      |> assign(:stats, %{})
      |> assign(:loading, true)
      |> assign(:show_clone_modal, false)
      |> assign(:clone_template, nil)
      |> assign(:clone_form, %{name: "", display_name: "", errors: %{}})
      |> assign_filter_defaults()
      |> assign_pagination_defaults()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_templates()
      |> load_stats()

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("filter", params, socket) do
    # Handle both search and filter parameters
    combined_params = %{}

    # Extract search parameters
    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    # Extract filter parameters
    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    # Reset to first page when filtering
    combined_params = Map.put(combined_params, "page", "1")

    # Build new URL parameters
    new_params = build_url_params(socket.assigns, combined_params)

    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/emails/templates?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/emails/templates"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_templates()
     |> load_stats()}
  end

  @impl true
  def handle_event("show_clone_modal", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      template ->
        {:noreply,
         socket
         |> assign(:show_clone_modal, true)
         |> assign(:clone_template, template)
         |> assign(:clone_form, %{
           name: "#{template.name}_copy",
           display_name: "#{template.display_name} (Copy)",
           errors: %{}
         })}
    end
  end

  @impl true
  def handle_event("hide_clone_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_clone_modal, false)
     |> assign(:clone_template, nil)
     |> assign(:clone_form, %{name: "", display_name: "", errors: %{}})}
  end

  @impl true
  def handle_event("validate_clone", %{"clone" => clone_params}, socket) do
    errors = validate_clone_form(clone_params)

    form = %{
      name: clone_params["name"] || "",
      display_name: clone_params["display_name"] || "",
      errors: errors
    }

    {:noreply, assign(socket, :clone_form, form)}
  end

  @impl true
  def handle_event("clone_template", %{"clone" => clone_params}, socket) do
    errors = validate_clone_form(clone_params)

    if map_size(errors) == 0 and socket.assigns.clone_template do
      case Templates.clone_template(
             socket.assigns.clone_template,
             String.trim(clone_params["name"]),
             %{display_name: clone_params["display_name"]}
           ) do
        {:ok, new_template} ->
          {:noreply,
           socket
           |> assign(:show_clone_modal, false)
           |> assign(:clone_template, nil)
           |> put_flash(:info, "Template cloned successfully as '#{new_template.name}'")
           |> push_navigate(to: Routes.path("/admin/emails/templates/#{new_template.id}/edit"))}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to clone template")}
      end
    else
      # Show validation errors
      form = %{
        name: clone_params["name"] || "",
        display_name: clone_params["display_name"] || "",
        errors: errors
      }

      {:noreply, assign(socket, :clone_form, form)}
    end
  end

  @impl true
  def handle_event("edit_template", %{"id" => template_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails/templates/#{template_id}/edit"))}
  end

  @impl true
  def handle_event("archive_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      %EmailTemplate{is_system: true} ->
        {:noreply,
         socket
         |> put_flash(:error, "System templates cannot be archived")}

      template ->
        case Templates.archive_template(template) do
          {:ok, _archived_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' archived successfully")
             |> load_templates()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to archive template")}
        end
    end
  end

  @impl true
  def handle_event("activate_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      template ->
        case Templates.activate_template(template) do
          {:ok, _activated_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' activated successfully")
             |> load_templates()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to activate template")}
        end
    end
  end

  @impl true
  def handle_event("delete_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      %EmailTemplate{is_system: true} ->
        {:noreply,
         socket
         |> put_flash(:error, "System templates cannot be deleted")}

      template ->
        case Templates.delete_template(template) do
          {:ok, _deleted_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' deleted successfully")
             |> load_templates()
             |> load_stats()}

          {:error, :system_template_protected} ->
            {:noreply,
             socket
             |> put_flash(:error, "System templates cannot be deleted")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to delete template")}
        end
    end
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Templates"
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
            <h1 class="text-4xl font-bold text-base-content mb-3">Email Templates</h1>
            <p class="text-lg text-base-content">Manage and organize your email templates</p>
          </div>
        </header>

        <%!-- Action Buttons --%>
        <div class="flex justify-end gap-2 mb-6">
          <.link navigate={Routes.path("/admin/emails/templates/new")} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Template
          </.link>

          <.button phx-click="refresh" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Refresh
          </.button>
        </div>

        <%!-- Statistics Summary --%>
        <div class="stats shadow mb-6">
          <div class="stat">
            <div class="stat-title">Total Templates</div>
            <div class="stat-value text-primary">{@stats[:total_templates] || 0}</div>
            <div class="stat-desc">All templates</div>
          </div>

          <div class="stat">
            <div class="stat-title">Active</div>
            <div class="stat-value text-success">{@stats[:active_templates] || 0}</div>
            <div class="stat-desc">Ready to use</div>
          </div>

          <div class="stat">
            <div class="stat-title">System</div>
            <div class="stat-value text-info">{@stats[:system_templates] || 0}</div>
            <div class="stat-desc">Core templates</div>
          </div>

          <div class="stat">
            <div class="stat-title">Most Used</div>
            <div class="stat-value text-secondary">
              <%= if @stats[:most_used] do %>
                {@stats[:most_used].usage_count}
              <% else %>
                0
              <% end %>
            </div>
            <div class="stat-desc">
              <%= if @stats[:most_used] do %>
                {@stats[:most_used].name}
              <% else %>
                No usage yet
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Filters & Search --%>
        <div class="card bg-base-100 shadow-sm mb-6">
          <div class="card-body">
            <.form for={%{}} phx-change="filter" phx-submit="filter" class="space-y-4">
              <%!-- Search Bar --%>
              <div class="form-control">
                <input
                  type="text"
                  name="search[query]"
                  value={@filters.search}
                  placeholder="Search by name, display name, or description..."
                  class="input input-bordered w-full"
                />
              </div>

              <%!-- Filter Row --%>
              <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                <%!-- Category Filter --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Category</span>
                  </label>
                  <select name="filter[category]" class="select select-bordered">
                    <option value="">All Categories</option>
                    <option value="system" selected={@filters.category == "system"}>System</option>
                    <option value="transactional" selected={@filters.category == "transactional"}>
                      Transactional
                    </option>
                    <option value="marketing" selected={@filters.category == "marketing"}>
                      Marketing
                    </option>
                  </select>
                </div>

                <%!-- Status Filter --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Status</span>
                  </label>
                  <select name="filter[status]" class="select select-bordered">
                    <option value="">All Statuses</option>
                    <option value="active" selected={@filters.status == "active"}>Active</option>
                    <option value="draft" selected={@filters.status == "draft"}>Draft</option>
                    <option value="archived" selected={@filters.status == "archived"}>
                      Archived
                    </option>
                  </select>
                </div>

                <%!-- System/Custom Filter --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Type</span>
                  </label>
                  <select name="filter[is_system]" class="select select-bordered">
                    <option value="">All Types</option>
                    <option value="true" selected={@filters.is_system == "true"}>System</option>
                    <option value="false" selected={@filters.is_system == "false"}>Custom</option>
                  </select>
                </div>

                <%!-- Clear Filters Button --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">&nbsp;</span>
                  </label>
                  <button type="button" phx-click="clear_filters" class="btn btn-ghost">
                    Clear Filters
                  </button>
                </div>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Templates Table --%>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-0">
            <%= if @loading do %>
              <div class="flex justify-center items-center h-32">
                <span class="loading loading-spinner loading-md"></span>
                <span class="ml-2">Loading templates...</span>
              </div>
            <% else %>
              <div class="w-full">
                <table class="table table-hover w-full">
                  <thead>
                    <tr>
                      <th class="w-1/4">Template</th>
                      <th class="w-1/4">Subject</th>
                      <th class="w-1/8">Category</th>
                      <th class="w-1/8">Status</th>
                      <th class="w-1/6">Usage</th>
                      <th class="w-1/8">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for template <- @templates do %>
                      <tr class="hover">
                        <%!-- Template Column --%>
                        <td>
                          <div class="space-y-1">
                            <div class="font-medium text-sm">{template.display_name}</div>
                            <div class="text-xs text-base-content/70">{template.name}</div>
                            <%= if template.is_system do %>
                              <div class="badge badge-info badge-xs">System</div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Subject Column --%>
                        <td>
                          <div class="text-sm truncate" title={template.subject}>
                            {template.subject}
                          </div>
                          <%= if template.description do %>
                            <div
                              class="text-xs text-base-content/70 truncate"
                              title={template.description}
                            >
                              {template.description}
                            </div>
                          <% end %>
                        </td>

                        <%!-- Category Column --%>
                        <td>
                          <%= if template.is_system do %>
                            <div class="badge badge-ghost badge-sm">
                              {String.capitalize(template.category)}
                            </div>
                          <% else %>
                            <div class={category_badge_class(template.category)}>
                              {String.capitalize(template.category)}
                            </div>
                          <% end %>
                        </td>

                        <%!-- Status Column --%>
                        <td>
                          <div class={status_badge_class(template.status)}>
                            {String.capitalize(template.status)}
                          </div>
                        </td>

                        <%!-- Usage Column --%>
                        <td>
                          <div class="space-y-1 text-xs">
                            <div class="font-medium">
                              {template.usage_count} uses
                            </div>
                            <%= if template.last_used_at do %>
                              <div class="text-base-content/70">
                                Last: {UtilsDate.format_date_with_user_format(template.last_used_at)}
                              </div>
                            <% else %>
                              <div class="text-base-content/70">Never used</div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Actions Column --%>
                        <td>
                          <div class="flex gap-1">
                            <%!-- Edit Button --%>
                            <button
                              phx-click="edit_template"
                              phx-value-id={template.id}
                              class="btn btn-xs btn-outline btn-primary"
                              title="Edit Template"
                            >
                              <.icon name="hero-pencil" class="w-3 h-3" />
                            </button>

                            <%!-- Clone Button --%>
                            <button
                              phx-click="show_clone_modal"
                              phx-value-id={template.id}
                              class="btn btn-xs btn-outline"
                              title="Clone Template"
                            >
                              <.icon name="hero-document-duplicate" class="w-3 h-3" />
                            </button>

                            <%!-- Archive/Activate Button (not for system templates) --%>
                            <%= unless template.is_system do %>
                              <%= if template.status == "active" do %>
                                <button
                                  phx-click="archive_template"
                                  phx-value-id={template.id}
                                  class="btn btn-xs btn-outline"
                                  title="Archive Template"
                                >
                                  <.icon name="hero-archive-box" class="w-3 h-3" />
                                </button>
                              <% else %>
                                <button
                                  phx-click="activate_template"
                                  phx-value-id={template.id}
                                  class="btn btn-xs btn-outline btn-success"
                                  title="Activate Template"
                                >
                                  <.icon name="hero-check-circle" class="w-3 h-3" />
                                </button>
                              <% end %>

                              <%!-- Delete Button --%>
                              <button
                                phx-click="delete_template"
                                phx-value-id={template.id}
                                class="btn btn-xs btn-outline text-error hover:btn-error"
                                onclick="return confirm('Are you sure you want to delete this template?')"
                                title="Delete Template"
                              >
                                <.icon name="hero-trash" class="w-3 h-3" />
                              </button>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>

                    <%= if length(@templates) == 0 and not @loading do %>
                      <tr>
                        <td colspan="6" class="text-center py-8 text-base-content/60">
                          No templates found matching your criteria
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <%!-- Pagination --%>
              <%= if @total_count > @per_page do %>
                <div class="border-t bg-base-200 px-4 py-3 flex items-center justify-between">
                  <div class="text-sm text-base-content/70">
                    Showing {(@page - 1) * @per_page + 1} to {min(@page * @per_page, @total_count)} of {@total_count} results
                  </div>

                  <div class="btn-group">
                    <%= if @page > 1 do %>
                      <.link patch={build_page_url(@page - 1, assigns)} class="btn btn-sm">
                        « Prev
                      </.link>
                    <% end %>

                    <%= for page_num <- pagination_pages(@page, @total_pages) do %>
                      <.link
                        patch={build_page_url(page_num, assigns)}
                        class={pagination_class(page_num, @page)}
                      >
                        {page_num}
                      </.link>
                    <% end %>

                    <%= if @page < @total_pages do %>
                      <.link patch={build_page_url(@page + 1, assigns)} class="btn btn-sm">
                        Next »
                      </.link>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Clone Template Modal --%>
        <div
          :if={@show_clone_modal}
          class="modal modal-open"
          phx-click-away="hide_clone_modal"
        >
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Clone Template</h3>
            <%= if @clone_template do %>
              <p class="text-sm text-base-content/70 mb-4">
                Creating a copy of "<strong>{@clone_template.display_name}</strong>"
              </p>
            <% end %>

            <.form
              for={%{}}
              phx-submit="clone_template"
              phx-change="validate_clone"
              class="space-y-4"
            >
              <div class="form-control">
                <label class="label">
                  <span class="label-text">New Template Name</span>
                </label>
                <input
                  type="text"
                  name="clone[name]"
                  value={@clone_form[:name] || ""}
                  placeholder="welcome_email_copy"
                  class={[
                    "input input-bordered w-full",
                    @clone_form[:errors][:name] && "input-error"
                  ]}
                  required
                />
                <%= if @clone_form[:errors][:name] do %>
                  <label class="label">
                    <span class="label-text-alt text-error">
                      {@clone_form[:errors][:name]}
                    </span>
                  </label>
                <% end %>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">New Display Name</span>
                </label>
                <input
                  type="text"
                  name="clone[display_name]"
                  value={@clone_form[:display_name] || ""}
                  placeholder="Welcome Email (Copy)"
                  class={[
                    "input input-bordered w-full",
                    @clone_form[:errors][:display_name] && "input-error"
                  ]}
                  required
                />
                <%= if @clone_form[:errors][:display_name] do %>
                  <label class="label">
                    <span class="label-text-alt text-error">
                      {@clone_form[:errors][:display_name]}
                    </span>
                  </label>
                <% end %>
              </div>

              <div class="modal-action">
                <button
                  type="button"
                  phx-click="hide_clone_modal"
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  Clone Template
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Helper Functions ---

  # Apply default filter values
  defp assign_filter_defaults(socket) do
    filters = %{
      search: "",
      category: "",
      status: "",
      is_system: ""
    }

    assign(socket, :filters, filters)
  end

  # Apply default pagination values
  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 0)
  end

  # Apply URL parameters to socket assigns
  defp apply_params(socket, params) do
    filters = %{
      search: params["search"] || "",
      category: params["category"] || "",
      status: params["status"] || "",
      is_system: params["is_system"] || ""
    }

    page = String.to_integer(params["page"] || "1")
    per_page = min(String.to_integer(params["per_page"] || "#{@default_per_page}"), @max_per_page)

    socket
    |> assign(:filters, filters)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
  end

  # Load templates based on current filters and pagination
  defp load_templates(socket) do
    %{filters: filters, page: page, per_page: per_page} = socket.assigns

    # Build filters for Templates query
    query_filters = build_query_filters(filters, page, per_page)

    templates = Templates.list_templates(query_filters)

    # Get total count for pagination
    total_count = Templates.count_templates(Map.drop(query_filters, [:limit, :offset]))

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:templates, templates)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:loading, false)
  end

  # Load template statistics
  defp load_stats(socket) do
    stats = Templates.get_template_stats()
    assign(socket, :stats, stats)
  end

  # Build query filters from form filters
  defp build_query_filters(filters, page, per_page) do
    query_filters = %{
      limit: per_page,
      offset: (page - 1) * per_page,
      order_by: :inserted_at,
      order_direction: :desc
    }

    # Add non-empty filters
    filters
    |> Enum.reduce(query_filters, fn
      {:search, search}, acc when search != "" ->
        Map.put(acc, :search, search)

      {:category, category}, acc when category != "" ->
        Map.put(acc, :category, category)

      {:status, status}, acc when status != "" ->
        Map.put(acc, :status, status)

      {:is_system, is_system}, acc when is_system != "" ->
        Map.put(acc, :is_system, is_system == "true")

      _, acc ->
        acc
    end)
  end

  # Build URL parameters from current state
  defp build_url_params(assigns, additional_params) do
    base_params = %{
      "search" => assigns.filters.search,
      "category" => assigns.filters.category,
      "status" => assigns.filters.status,
      "is_system" => assigns.filters.is_system,
      "page" => assigns.page,
      "per_page" => assigns.per_page
    }

    Map.merge(base_params, additional_params)
    |> Enum.reject(fn {_key, value} -> value == "" or is_nil(value) end)
    |> Map.new()
    |> URI.encode_query()
  end

  # Helper functions for template

  defp category_badge_class(category) do
    case category do
      "system" -> "badge badge-info badge-sm"
      "marketing" -> "badge badge-secondary badge-sm"
      "transactional" -> "badge badge-primary badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp status_badge_class(status) do
    case status do
      "active" -> "badge badge-success badge-sm"
      "draft" -> "badge badge-warning badge-sm"
      "archived" -> "badge badge-ghost badge-sm"
      _ -> "badge badge-neutral badge-sm"
    end
  end

  defp pagination_pages(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)

    start_page..end_page
  end

  defp pagination_class(page_num, current_page) do
    if page_num == current_page do
      "btn btn-sm btn-active"
    else
      "btn btn-sm"
    end
  end

  defp build_page_url(page, assigns) do
    params = build_url_params(assigns, %{"page" => page})
    Routes.path("/admin/emails/templates?#{params}")
  end

  # Validate clone form
  defp validate_clone_form(params) do
    errors = %{}

    # Validate name
    errors =
      case String.trim(params["name"] || "") do
        "" ->
          Map.put(errors, :name, "Name is required")

        name ->
          if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
            # Check if name already exists
            case Templates.get_template_by_name(name) do
              nil -> errors
              _ -> Map.put(errors, :name, "Name already exists")
            end
          else
            Map.put(
              errors,
              :name,
              "Must start with a letter and contain only lowercase letters, numbers, and underscores"
            )
          end
      end

    # Validate display_name
    errors =
      case String.trim(params["display_name"] || "") do
        "" ->
          Map.put(errors, :display_name, "Display name is required")

        _ ->
          errors
      end

    errors
  end
end
