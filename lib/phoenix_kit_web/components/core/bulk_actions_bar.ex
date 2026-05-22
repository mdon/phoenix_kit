defmodule PhoenixKitWeb.Components.Core.BulkActionsBar do
  @moduledoc """
  Floating bulk-action bar — shown when a list view has selected rows.

  Wraps a row of action buttons in a styled container with a "N selected"
  counter on the left and a Clear button on the right. The container's
  visual style is fully consumer-controlled via `wrapper_class`, so a
  single component covers the inline cards used by entities and the
  sticky/blurred bars used by catalogue.

  The consumer owns selection state — typically a
  `selected_uuids :: MapSet.t()` assign, toggled via `phx-click="toggle_select"`
  on per-row checkboxes. This component only renders the bar; it
  doesn't define the checkboxes or store state.

  ## Attributes

  - `count` — Number of selected rows. The bar is hidden when `count == 0`.
    Required.
  - `clear_event` — Phoenix event name fired by the Clear button. Default
    `"deselect_all"`.
  - `target` — Optional `phx-target` for LiveComponents.
  - `wrapper_class` — Classes for the outer wrapper. **Replaces** the
    default (`"card bg-base-200 shadow-md mb-4 p-3"`). Pass a sticky /
    blurred variant for top-of-list placement.
  - `class` — Extra classes appended after `wrapper_class`.

  ## Slots

  - `inner_block` — Action buttons. Render `<button phx-click="bulk_action"
    phx-value-action="...">` controls; this component lays them out in a
    horizontal flex row between the count and the Clear button. Required.

  ## Plug-in examples

  ### Inline card (entities Data Navigator style)

      <.bulk_actions_bar
        count={MapSet.size(@selected_uuids)}
        clear_event="deselect_all"
      >
        <button
          phx-click="bulk_action"
          phx-value-action="archive"
          phx-disable-with={gettext("…")}
          class="btn btn-warning btn-sm"
        >
          <.icon name="hero-archive-box" class="w-4 h-4" /> {gettext("Archive")}
        </button>
        <button
          phx-click="bulk_action"
          phx-value-action="trash"
          phx-disable-with={gettext("…")}
          class="btn btn-error btn-sm"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Trash")}
        </button>
      </.bulk_actions_bar>

  ### Sticky bar (catalogue Items / Categories style)

      <.bulk_actions_bar
        count={MapSet.size(@selected_items)}
        clear_event="clear_selection"
        wrapper_class="sticky top-[72px] z-40 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur"
      >
        <button phx-click="request_bulk_move_items" class="btn btn-sm btn-outline">
          <.icon name="hero-arrows-right-left" class="w-4 h-4" /> {gettext("Move")}
        </button>
        <button phx-click="request_bulk_delete_items" class="btn btn-sm btn-outline btn-error">
          <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
        </button>
      </.bulk_actions_bar>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :count, :integer, required: true
  attr :clear_event, :string, default: "deselect_all"
  attr :target, :any, default: nil

  attr :wrapper_class, :any,
    default: "card bg-base-200 shadow-md mb-4 p-3",
    doc:
      "Outer wrapper classes. Replaces the default; pass a sticky / blurred variant for top-of-list placement."

  attr :class, :string, default: nil

  slot :inner_block, required: true

  def bulk_actions_bar(assigns) do
    ~H"""
    <div
      :if={@count > 0}
      class={["flex flex-wrap items-center gap-3", @wrapper_class, @class]}
    >
      <span class="text-sm font-medium whitespace-nowrap">
        {gettext("%{count} selected", count: @count)}
      </span>
      {render_slot(@inner_block)}
      <button
        type="button"
        phx-click={@clear_event}
        phx-target={@target}
        class="btn btn-ghost btn-sm ml-auto"
      >
        <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear")}
      </button>
    </div>
    """
  end
end
