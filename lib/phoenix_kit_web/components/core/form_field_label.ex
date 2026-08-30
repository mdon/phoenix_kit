defmodule PhoenixKitWeb.Components.Core.FormFieldLabel do
  @moduledoc """
  Provides a label UI component for form components.
  """
  use Phoenix.Component

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <%!-- Plain font-semibold, matching <.input>'s inline label
    (2026-08-31): `fieldset-legend` is daisyUI 5's hook for legends
    inside a real `.fieldset`, and borrowed inside `.label` it shrank
    and muted Select/Textarea labels next to full-size Input ones —
    the "Unit looks different from the fields around it" bug. --%>
    <label for={@for} class={["label", @class]}>
      <span class="font-semibold">
        {render_slot(@inner_block)}
      </span>
    </label>
    """
  end
end
