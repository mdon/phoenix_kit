defmodule PhoenixKitWeb.Components.Core.Pagination do
  @moduledoc """
  Pagination components for list views in PhoenixKit.

  Provides pagination controls and information display following daisyUI design patterns.
  """

  use Phoenix.Component

  @doc """
  Displays pagination controls with page numbers and navigation buttons.

  ## Attributes
  - `page` - Current page number (required)
  - `total_pages` - Total number of pages (required)
  - `build_url` - Function that takes page number and returns URL (required)
  - `class` - Additional CSS classes

  ## Examples

      <.pagination_controls
        page={@page}
        total_pages={@total_pages}
        build_url={&build_page_url(&1, assigns)}
      />
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :build_url, :any, required: true
  attr :class, :string, default: ""

  def pagination_controls(assigns) do
    ~H"""
    <div class={["btn-group", @class]}>
      <%= if @page > 1 do %>
        <.link patch={@build_url.(@page - 1)} class="btn btn-sm">
          « Prev
        </.link>
      <% end %>

      <%= for page_num <- pagination_range(@page, @total_pages) do %>
        <.link
          patch={@build_url.(page_num)}
          class={["btn btn-sm", page_num == @page && "btn-active"]}
        >
          {page_num}
        </.link>
      <% end %>

      <%= if @page < @total_pages do %>
        <.link patch={@build_url.(@page + 1)} class="btn btn-sm">
          Next »
        </.link>
      <% end %>
    </div>
    """
  end

  @doc """
  Displays pagination information showing result range.

  ## Attributes
  - `page` - Current page number (required)
  - `per_page` - Items per page (required)
  - `total_count` - Total number of items (required)
  - `class` - Additional CSS classes

  ## Examples

      <.pagination_info
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
      />

      # Renders: "Showing 1 to 25 of 100 results"
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true
  attr :class, :string, default: ""

  def pagination_info(assigns) do
    ~H"""
    <div class={["text-sm text-base-content/70", @class]}>
      Showing {(@page - 1) * @per_page + 1} to {min(@page * @per_page, @total_count)} of {@total_count} results
    </div>
    """
  end

  # Private helper functions

  # Calculate visible page range (current page ± 2)
  defp pagination_range(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    start_page..end_page
  end
end
