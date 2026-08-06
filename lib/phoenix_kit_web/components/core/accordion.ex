defmodule PhoenixKitWeb.Components.Core.Accordion do
  @moduledoc """
  Collapsible content section on the native `<details>` element + daisyUI
  `collapse` styling.

  The browser owns the open/closed state: the summary click toggles
  natively (instant, no round trip) and daisyUI 5 animates the reveal
  via its `::details-content` height transition. `JS.ignore_attributes`
  marks `open` as client-owned on mount, so LiveView patches never
  reset a section the user toggled — the historic "accordion slams
  shut on the next update" morphdom bug.

  `open` sets only the INITIAL state (server changes to it after mount
  are ignored by design). To open a section from elsewhere in the page,
  set the attribute client-side:

      <button type="button" phx-click={JS.set_attribute({"open", ""}, to: "#advanced")}>
        Show advanced settings
      </button>

  Works without JavaScript (native `<details>` on dead renders).

  Closing a section near the bottom of a long page would shrink the document
  out from under the reader and jump the viewport upward; the collapse scroll
  keeper in `priv/static/assets/phoenix_kit.js` holds the page height instead,
  so the reader stays put. It keys off `class="collapse"` on the `<details>`,
  which this component always emits.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :open, :boolean, default: false, doc: "initial state only — client-owned after mount"
  attr :class, :any, default: nil, doc: "extra classes on the <details>"
  attr :title_class, :any, default: nil, doc: "extra classes on the summary"

  slot :title, required: true
  slot :content, required: true

  def accordion(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      phx-mounted={JS.ignore_attributes(["open"])}
      class={["collapse collapse-arrow border border-base-200 bg-base-100", @class]}
    >
      <summary class={["collapse-title text-sm font-semibold", @title_class]}>
        {render_slot(@title)}
      </summary>
      <div class="collapse-content">
        {render_slot(@content)}
      </div>
    </details>
    """
  end
end
