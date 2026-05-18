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
  - `:subtitle` — Optional helper text rendered under the title. Slot
    (not attr) so callers can drop a `<.pk_link>` / `<.icon>` / etc.
    inline.

  ## Example

      <.form_section title={gettext("Provider Configuration")}>
        <:subtitle>
          {gettext("Credentials live in")}
          <.pk_link navigate="/admin/settings/integrations" class="link link-primary">
            Settings → Integrations
          </.pk_link>.
        </:subtitle>
        <.select field={@form[:provider]} ... />
      </.form_section>

      <.form_section title={gettext("Basic Information")} body_class="space-y-4">
        <.input field={@form[:name]} label="Name" required />
      </.form_section>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  attr :body_class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle

  def form_section(assigns) do
    ~H"""
    <section class={["card bg-base-100 shadow-lg", @class]}>
      <div class={["card-body", @body_class]}>
        <h2 class="card-title text-lg">
          <.icon :if={@icon} name={@icon} class="w-5 h-5" /> {@title}
        </h2>
        <p :if={@subtitle != []} class="text-sm text-base-content/60 -mt-1">
          {render_slot(@subtitle)}
        </p>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
