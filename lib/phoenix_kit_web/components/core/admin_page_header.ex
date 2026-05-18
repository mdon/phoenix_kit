defmodule PhoenixKitWeb.Components.Core.AdminPageHeader do
  @moduledoc """
  Provides a unified admin page header component with optional back button,
  title, subtitle, and action slots.

  Replaces the 7+ different header patterns previously used across admin templates,
  providing a consistent inline flex layout with responsive behavior.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders an admin page header with title, subtitle, and optional actions.

  For simple headers, use `title` and `subtitle` attributes. For complex headers
  with rich content (badges, metadata), use `inner_block` to provide custom title
  markup that replaces the default title/subtitle rendering.

  ## Attributes

  - `title` - Page title as a string attribute
  - `subtitle` - Page subtitle as a string attribute
  - `back` - Deprecated, no-op. Retained so existing callers compile; the back
    arrow no longer renders. Remove from call sites at your convenience.
  - `back_click` - Deprecated, no-op. Same rationale as `back`.

  ## Slots

  - `:inner_block` - Custom title/subtitle markup (overrides `title`/`subtitle` attrs)
  - `:actions` - Action buttons rendered on the right side

  ## Examples

      <%!-- Basic --%>
      <.admin_page_header title="User Management" />

      <%!-- With subtitle --%>
      <.admin_page_header title="Settings" subtitle="Configure system" />

      <%!-- With actions --%>
      <.admin_page_header title="Posts">
        <:actions>
          <button class="btn btn-primary btn-sm">New Post</button>
        </:actions>
      </.admin_page_header>

      <%!-- Rich title content --%>
      <.admin_page_header>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">Invoice #123</h1>
        <p class="text-sm text-base-content/60 mt-0.5">Created 2 days ago</p>
      </.admin_page_header>
  """
  attr :back, :string, default: nil
  attr :back_click, :string, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  slot :inner_block
  slot :actions

  def admin_page_header(assigns) do
    ~H"""
    <header class="mb-3 sm:mb-6">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div class="flex items-center gap-3">
          <div>
            <%= if @title do %>
              <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">
                {@title}
              </h1>
              <p :if={@subtitle} class="text-sm sm:text-base text-base-content/60 mt-0.5">
                {@subtitle}
              </p>
            <% else %>
              {render_slot(@inner_block)}
            <% end %>
          </div>
        </div>
        <div
          :if={@actions != []}
          class="flex flex-wrap items-center gap-2 sm:flex-shrink-0 [&>*]:w-full [&>*]:sm:w-auto"
        >
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end
end
