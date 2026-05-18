defmodule PhoenixKitWeb.Components.Core.BulkActionsBar do
  @moduledoc """
  Floating bulk-action bar — shown when a list view has selected rows.

  Lifts the pattern used by the entities Data Navigator
  (`PhoenixKitEntities.Web.DataNavigator`) into a reusable primitive:
  a card with a "N selected" counter, a slot for action buttons, and a
  Clear button on the right that fires `deselect_all`.

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
  - `class` — Extra classes appended to the outer card.

  ## Slots

  - `inner_block` — Action buttons. Render `<button phx-click="bulk_action"
    phx-value-action="...">` controls; this component lays them out in a
    flex row. Required.

  ## Example

      <.bulk_actions_bar count={MapSet.size(@selected_uuids)}>
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
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :count, :integer, required: true
  attr :clear_event, :string, default: "deselect_all"
  attr :target, :any, default: nil
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def bulk_actions_bar(assigns) do
    ~H"""
    <div :if={@count > 0} class={["card bg-base-200 shadow-md mb-4", @class]}>
      <div class="card-body p-3">
        <div class="flex flex-wrap gap-3 items-center">
          <span class="text-sm font-semibold whitespace-nowrap">
            {@count} {gettext("selected")}
          </span>
          <div class="divider divider-horizontal mx-0"></div>
          {render_slot(@inner_block)}
          <div class="flex-1"></div>
          <button
            type="button"
            phx-click={@clear_event}
            phx-target={@target}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
