defmodule PhoenixKitWeb.Components.Core.Checkbox do
  @moduledoc """
  Provides a default checkbox UI component.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders a checkbox.
  """
  attr :field, Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :errors, :list, default: []
  # nil (the default) means "derive from the field's value". A non-nil
  # default would defeat that: attr defaults are materialized into assigns
  # before the component runs, so `assign_new` in the field clause would
  # never fire and a field-bound checkbox would ALWAYS render unchecked.
  attr :checked, :boolean, default: nil

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the `<input type=\"checkbox\">` (e.g. `checkbox-sm`, `checkbox-accent`)"

  attr :rest, :global, include: ~w(readonly required)

  slot :inner_block

  def checkbox(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    derived = Form.normalize_value("checkbox", field.value)

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign(:checked, if(is_nil(assigns.checked), do: derived, else: assigns.checked))
    |> checkbox()
  end

  def checkbox(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label class={[
        "flex gap-4 text-sm leading-6 text-base-content",
        (@inner_block != [] && "items-start") || "items-center"
      ]}>
        <input type="hidden" name={@name} value="false" />

        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["checkbox checkbox-primary", @inner_block != [] && "mt-0.5", @class]}
          {@rest}
        />

        <span class="select-none cursor-pointer">
          <span class={@inner_block != [] && "font-medium"}>{@label}</span>
          <span :if={@inner_block != []} class="block text-xs text-base-content/60">
            {render_slot(@inner_block)}
          </span>
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
