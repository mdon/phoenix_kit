defmodule PhoenixKitWeb.Components.Core.FormFieldLabel do
  @moduledoc """
  Provides a label UI component for form components.
  """
  use Phoenix.Component

  @doc """
  Renders a label.

  Markup is `<.input>`'s label, byte for byte, so a `<.select>` or
  `<.textarea>` label is indistinguishable from an `<.input>` one beside it.
  """
  attr :for, :string, default: nil
  attr :class, :string, default: nil

  attr :required, :boolean,
    default: false,
    doc: "Renders the red required marker as a sibling span, exactly as `<.input>` does."

  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <%!-- Plain font-semibold, matching <.input>'s inline label.
    `fieldset-legend` is daisyUI 5's hook for legends inside a real
    `.fieldset`. It sets NO font-size — what it does set is
    `color: var(--color-base-content)` (overriding `.label`'s 60%-alpha
    muting) plus `padding-block: 0.5rem`. Borrowed inside `.label` it
    therefore made Select/Textarea labels darker and taller than the
    Input ones beside them: the "Unit looks different from the fields
    around it" bug. `mb-2` is carried here rather than by each caller —
    `fieldset-legend`'s padding was the only bottom gap the bare
    call sites had. --%>
    <label for={@for} class={["label mb-2", @class]}>
      <span class="font-semibold">
        {render_slot(@inner_block)}
      </span>
      <span :if={@required} class="text-error ml-0.5" aria-hidden="true">*</span>
    </label>
    """
  end
end
