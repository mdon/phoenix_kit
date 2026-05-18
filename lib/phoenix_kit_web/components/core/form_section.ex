defmodule PhoenixKitWeb.Components.Core.FormSection do
  @moduledoc """
  Card-wrapped form section with a titled header.

  Replaces the repeated boilerplate:

      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <h2 class="card-title text-lg">Section Name</h2>
          ...fields...
        </div>
      </div>

  with a single component call. Used in every form-heavy admin page.

  ## Attributes

  - `title` — Section heading text. Required.
  - `icon` — Optional Heroicon name rendered before the title (e.g.
    `"hero-cog-6-tooth"`).
  - `class` — Extra classes appended to the outer card wrapper.
  - `body_class` — Extra classes appended to the card body wrapper
    (typical use: `"space-y-4"` for vertical field spacing).

  ## Slots

  - `inner_block` — Section content (form fields). Required.

  ## Example

      <.form_section title={gettext("Basic Information")} body_class="space-y-4">
        <.input field={@form[:name]} label="Name" required />
        <.textarea field={@form[:description]} label="Description" />
      </.form_section>

      <.form_section title={gettext("Configuration")} icon="hero-cog-6-tooth">
        ...
      </.form_section>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  attr :body_class, :string, default: nil

  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <section class={["card bg-base-100 shadow-lg", @class]}>
      <div class={["card-body", @body_class]}>
        <h2 class="card-title text-lg">
          <.icon :if={@icon} name={@icon} class="w-5 h-5" /> {@title}
        </h2>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
