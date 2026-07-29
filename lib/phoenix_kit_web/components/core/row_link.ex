defmodule PhoenixKitWeb.Components.Core.RowLink do
  @moduledoc """
  Stretched link that makes a whole table row (or card) clickable with a
  single real `<a>` element.

  Render it once at the START of the row's first cell. The row (or card)
  must be a positioned ancestor (`relative`); the link paints an
  `::after` overlay across it. Interactive siblings — row menus, buttons,
  other links — need `relative z-10` to stay clickable above the overlay.
  The link's accessible name comes from `label` (visually hidden).

  ## Table rows need `row-link-host` (Safari)

  Safari/WebKit ignores `position: relative` on `<tr>`, so on a `<tr>` host the
  overlay escapes to the `<table>` and every row's overlay collapses onto the
  last row — on iOS/iPadOS every row then navigates to the LAST one. Add the
  `row-link-host` class (see `app.css`) to any `<tr>` host; it applies a
  `transform` that WebKit *does* honor as a containing block. Card/`<div>`
  hosts don't need it.

  ## Example

      <.table_default_row class="row-link-host relative cursor-pointer">
        <.table_default_cell>
          <.row_link navigate={~p"/orders/123"} label="Open order #123" />
          #123
        </.table_default_cell>
        <.table_default_cell class="relative z-10"><.table_row_menu .../></.table_default_cell>
      </.table_default_row>
  """
  use Phoenix.Component

  attr :navigate, :string, required: true
  attr :label, :string, required: true, doc: "accessible name for the link (rendered sr-only)"

  def row_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="after:absolute after:inset-0 after:z-0">
      <span class="sr-only">{@label}</span>
    </.link>
    """
  end
end
