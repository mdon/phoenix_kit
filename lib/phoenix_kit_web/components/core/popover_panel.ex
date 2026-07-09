defmodule PhoenixKitWeb.Components.Core.PopoverPanel do
  @moduledoc """
  An anchored popover panel for arbitrary rich content — filter panels,
  pickers, mini-forms — that opens INSTANTLY.

  Open/close is pure client-side (`Phoenix.LiveView.JS`): the panel is
  always rendered (hidden), and the trigger toggles it without a server
  round-trip, so there is no perceptible delay and nothing to spin on.
  Backdrop click and Escape hide it the same way. LiveView's JS commands
  are DOM-patch aware, so server re-renders (e.g. the panel's own
  interactions updating assigns) don't flip the panel shut.

  Unlike `TableRowMenu` (a JS-hook dropdown for short action lists), this
  holds any markup: forms, search inputs, scrollable checklists —
  interacting inside never closes it (the click-away backdrop paints
  BELOW the card; keep that stacking).

  ## Layout contract

  Render the panel INSIDE a `relative` wrapper next to its trigger; on
  `sm+` screens the card anchors under the trigger (aligned via `:align`),
  while on small screens it becomes a full-screen overlay with a dimmed
  backdrop.

  ## Example

      <div class="relative">
        <button type="button" phx-click={toggle_popover("my-filters")} class="btn btn-sm">
          Filters
        </button>

        <.popover_panel id="my-filters">
          <form phx-change="search">…</form>
          <ul class="max-h-80 overflow-y-auto">…</ul>
        </.popover_panel>
      </div>

  Since content inside still talks to the server, give those interactions
  their own loading affordances, e.g. a spinner revealed by the form's
  `phx-change-loading` class:

      <span class={["loading loading-spinner loading-xs invisible",
                    "[.phx-change-loading_&]:visible"]} />
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Client-side command that toggles the panel with a quick fade/scale.
  Attach to the trigger's `phx-click` (composable with other JS commands).
  """
  def toggle_popover(js \\ %JS{}, id) do
    JS.toggle(js,
      to: "##{id}",
      in: {"transition ease-out duration-100", "opacity-0 scale-95", "opacity-100 scale-100"},
      out: {"transition ease-in duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
  end

  @doc """
  Client-side command that hides the panel. Used internally by the
  backdrop and Escape; exposed for custom close buttons inside the panel.
  """
  def hide_popover(js \\ %JS{}, id) do
    JS.hide(js,
      to: "##{id}",
      transition: {"transition ease-in duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
  end

  @doc """
  Renders the (initially hidden) popover panel. Toggle it with
  `toggle_popover/2` on the trigger.

  ## Attributes

  - `id` - DOM id (required; the toggle/hide commands target it)
  - `align` - which trigger edge the card hugs on `sm+`: `"end"` (right,
    default) or `"start"` (left)
  - `width_class` - card width on `sm+` (default `"sm:w-96"`); complete
    class strings only (Tailwind purge)
  - `class` - extra classes merged onto the card

  ## Slots

  - `inner_block` - the panel content (required)
  """
  attr :id, :string, required: true
  attr :align, :string, default: "end", values: ["end", "start"]
  attr :width_class, :string, default: "sm:w-96"
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def popover_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "hidden fixed inset-0 z-40 sm:absolute sm:inset-auto sm:top-full sm:mt-2",
        align_class(@align)
      ]}
      phx-window-keydown={hide_popover(@id)}
      phx-key="escape"
      role="dialog"
      aria-modal="true"
    >
      <%!-- click-away backdrop: dims on mobile, invisible on desktop.
           It must stay BELOW the card — with the card static the backdrop
           paints on top and swallows every click/scroll inside the panel. --%>
      <div
        class="fixed inset-0 bg-base-content/30 sm:bg-transparent"
        phx-click={hide_popover(@id)}
        aria-hidden="true"
      >
      </div>

      <div class={[
        "absolute inset-x-2 top-12 z-10",
        "sm:relative sm:inset-auto sm:top-auto",
        @width_class,
        "card bg-base-100 shadow-xl border border-base-content/10",
        @class
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # The wrapper is a full-viewport fixed layer on mobile; on sm+ it collapses
  # to an absolute anchor under the trigger, hugging the chosen edge.
  defp align_class("start"), do: "sm:left-0"
  defp align_class(_end), do: "sm:right-0"
end
