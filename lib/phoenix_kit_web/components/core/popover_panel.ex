defmodule PhoenixKitWeb.Components.Core.PopoverPanel do
  @moduledoc """
  An anchored popover panel for arbitrary rich content — filter panels,
  pickers, mini-forms — with click-away and Escape-to-close.

  Unlike `TableRowMenu` (a JS-hook dropdown for short action lists), this
  is LiveView-state-driven and holds any markup: forms, search inputs,
  scrollable checklists. The open/close state lives in the caller's
  assigns, so the panel survives re-renders and interacting with inputs
  inside it never closes it.

  ## Layout contract

  Render the panel INSIDE a `relative` wrapper next to its trigger; on
  `sm+` screens the card anchors under the trigger (aligned via `:align`),
  while on small screens it becomes a full-screen overlay with a dimmed
  backdrop. The click-away backdrop always paints BELOW the card (the card
  is `relative z-10` over the `fixed` backdrop — keeping that ordering is
  what makes clicks and scrolls inside the panel safe).

  ## Example

      <div class="relative">
        <button type="button" phx-click="toggle_panel" class="btn btn-sm">
          Filters
        </button>

        <.popover_panel :if={@panel_open} id="my-filters" on_close="close_panel">
          <form phx-change="search">…</form>
          <ul class="max-h-80 overflow-y-auto">…</ul>
        </.popover_panel>
      </div>

  The caller owns the state:

      def handle_event("toggle_panel", _p, socket),
        do: {:noreply, assign(socket, :panel_open, not socket.assigns.panel_open)}

      def handle_event("close_panel", _p, socket),
        do: {:noreply, assign(socket, :panel_open, false)}
  """

  use Phoenix.Component

  @doc """
  Renders the anchored popover panel.

  ## Attributes

  - `id` - DOM id (required)
  - `on_close` - event pushed on backdrop click and Escape (required)
  - `align` - which trigger edge the card hugs on `sm+`: `"end"` (right,
    default) or `"start"` (left)
  - `width_class` - card width on `sm+` (default `"sm:w-96"`); complete
    class strings only (Tailwind purge)
  - `class` - extra classes merged onto the card

  ## Slots

  - `inner_block` - the panel content (required)
  """
  attr :id, :string, required: true
  attr :on_close, :string, required: true
  attr :align, :string, default: "end", values: ["end", "start"]
  attr :width_class, :string, default: "sm:w-96"
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def popover_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "fixed inset-0 z-40 sm:absolute sm:inset-auto sm:top-full sm:mt-2",
        align_class(@align)
      ]}
      phx-window-keydown={@on_close}
      phx-key="escape"
      role="dialog"
      aria-modal="true"
    >
      <%!-- click-away backdrop: dims on mobile, invisible on desktop.
           It must stay BELOW the card (see moduledoc). --%>
      <div
        class="fixed inset-0 bg-base-content/30 sm:bg-transparent"
        phx-click={@on_close}
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
