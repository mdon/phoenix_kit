defmodule PhoenixKitWeb.Components.Core.Accordion do
  @moduledoc """
  Collapsible content section on the native `<details>` element + daisyUI
  `collapse` styling.

  Rewritten 2026-08-06: the previous version emitted literal `\#{...}`
  class text (string interpolation inside a plain HEEx attribute never
  runs) and depended on `.accordion-*` CSS no host defines — it could
  not have worked anywhere.

  ## Two modes

  - **Uncontrolled** (default): the browser toggles the section — fine on
    dead renders and static pages. In a connected LiveView any patch
    resets the element to the server-rendered state (morphdom re-applies
    the missing `open` attribute), so a section the user opened slams
    shut on the next update.
  - **Server-tracked** (recommended in LiveViews): pass `open` +
    `toggle_event` (+ `toggle_value`). The summary click still toggles
    natively — instant, no round-trip flicker — and the event mirrors the
    state into an assign so re-renders agree with what the user sees:

        <.accordion
          id="advanced"
          open={@open_sections["advanced"]}
          toggle_event="toggle_section"
          toggle_value="advanced"
        >
          <:title>Advanced</:title>
          <:content>…</:content>
        </.accordion>

        def handle_event("toggle_section", %{"key" => key}, socket) do
          open = socket.assigns.open_sections
          {:noreply,
           assign(socket, open_sections: Map.put(open, key, not Map.get(open, key, false)))}
        end

  Works without JavaScript in both modes (native `<details>`).
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :open, :boolean, default: false

  attr :toggle_event, :string,
    default: nil,
    doc: "phx-click on the summary; sends %{\"key\" => toggle_value}"

  attr :toggle_value, :string, default: nil
  attr :class, :any, default: nil, doc: "extra classes on the <details>"
  attr :title_class, :any, default: nil, doc: "extra classes on the summary"

  slot :title, required: true
  slot :content, required: true

  def accordion(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      class={["collapse collapse-arrow border border-base-200 bg-base-100", @class]}
    >
      <summary
        class={["collapse-title text-sm font-semibold", @title_class]}
        phx-click={@toggle_event}
        phx-value-key={@toggle_value}
      >
        {render_slot(@title)}
      </summary>
      <div class="collapse-content">
        {render_slot(@content)}
      </div>
    </details>
    """
  end
end
