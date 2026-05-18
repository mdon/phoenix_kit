defmodule PhoenixKitWeb.Components.Core.EmptyState do
  @moduledoc """
  Standardised "no rows" panel for list views.

  Three visual variants, all with the same attr shape:

  - `variant="compact"` (default) — small centered text with optional
    icon and CTA. No card chrome. Fits inside an existing section. Use
    for "no rows match this filter" or "no items in this sub-list".

  - `variant="card"` — same content as `compact` but wrapped in a
    `card bg-base-100 shadow` for slightly more visual presence. Use
    when the empty-state stands alone in the page body (search-result-
    empty pages, etc.).

  - `variant="featured"` — dashed-border card with a big icon, large
    heading, description, and CTA. Use for the "your list is genuinely
    empty, here's how to get started" first-run state.

  ## Attributes

  - `title` — Required heading text.
  - `icon` — Optional Heroicon name shown above the title.
  - `description` — Optional sub-text below the title.
  - `variant` — `"compact"` (default) or `"featured"`.
  - `class` — Extra classes on the wrapper. `compact` defaults to
    `py-16` when this is `nil`; pass `"py-10"` etc. to override.

  ## Slots

  - `inner_block` — Optional CTA content rendered below the description.
  - `:cta` — Same as `inner_block` (compat alias used by some callers).

  ## Examples

      <%!-- Compact (default) — "no rows match this filter" --%>
      <.empty_state icon="hero-clipboard-document-list" title={gettext("No projects match.")} />

      <%!-- Compact with CTA --%>
      <.empty_state icon="hero-rectangle-stack" title={gettext("No tasks yet.")}>
        <.link navigate={Paths.new_task()} class="link link-primary text-sm">
          {gettext("Create your first")}
        </.link>
      </.empty_state>

      <%!-- Featured — first-run hero state --%>
      <.empty_state
        variant="featured"
        icon="hero-cpu-chip"
        title={gettext("No Endpoints Yet")}
        description={gettext("Create your first AI endpoint to get started.")}
      >
        <.link navigate={...} class="btn btn-primary btn-lg">
          <.icon name="hero-plus" class="w-5 h-5 mr-2" /> {gettext("Create First Endpoint")}
        </.link>
      </.empty_state>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :description, :string, default: nil
  attr :variant, :string, default: "compact", values: ~w(compact card featured)
  attr :class, :string, default: nil

  slot :inner_block
  slot :cta

  def empty_state(%{variant: "featured"} = assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-xl border-2 border-dashed border-base-300", @class]}>
      <div class="card-body text-center py-12">
        <div :if={@icon} class="mb-4 opacity-50">
          <.icon name={@icon} class="w-16 h-16 mx-auto" />
        </div>
        <h3 class="text-2xl font-semibold text-base-content/60 mb-4">{@title}</h3>
        <p :if={@description} class="text-base-content/50 mb-6 max-w-md mx-auto">
          {@description}
        </p>
        <div :if={@inner_block != [] or @cta != []}>
          {render_slot(@inner_block)}
          {render_slot(@cta)}
        </div>
      </div>
    </div>
    """
  end

  def empty_state(%{variant: "card"} = assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow", @class]}>
      <div class="card-body items-center text-center py-12">
        <.icon :if={@icon} name={@icon} class="w-12 h-12 mb-2 opacity-40" />
        <p class="text-base-content/60">{@title}</p>
        <p :if={@description} class="text-sm text-base-content/50">{@description}</p>
        <div :if={@inner_block != [] or @cta != []} class="mt-2">
          {render_slot(@inner_block)}
          {render_slot(@cta)}
        </div>
      </div>
    </div>
    """
  end

  def empty_state(assigns) do
    # `@class || "py-16"` would let an empty string (`""`) clobber the
    # default padding. Treat empty string the same as nil so consumers
    # passing `class=""` (e.g. from a conditional) still get sane padding.
    padding = if assigns.class in [nil, ""], do: "py-16", else: assigns.class
    assigns = assign(assigns, :wrapper_padding, padding)

    ~H"""
    <div class={["text-center text-base-content/60", @wrapper_padding]}>
      <.icon :if={@icon} name={@icon} class="w-12 h-12 mx-auto mb-2 opacity-40" />
      <p class="text-sm font-medium">{@title}</p>
      <p :if={@description} class="text-xs text-base-content/50 mt-1">{@description}</p>
      <div :if={@inner_block != [] or @cta != []} class="mt-3">
        {render_slot(@inner_block)}
        {render_slot(@cta)}
      </div>
    </div>
    """
  end
end
