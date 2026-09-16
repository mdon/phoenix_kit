defmodule PhoenixKitWeb.Components.Core.DecimalInput do
  @moduledoc """
  A form control for numbers a person types — quantities, prices, weights,
  lengths — where a comma and a dot must both work and nothing may be
  rounded.

  Why not `<.input type="number">`: the browser owns a number control. Its
  decimal separator follows the page/element locale, so on a page with
  `lang="et"` a typed `2.5` can be swallowed (the field submits `""`), and
  on `lang="en"` a typed `2,5` is; `step` makes any other precision
  invalid and silently blocks a `phx-submit`; the spinner arrows steal
  wheel and arrow-key events. This component renders a plain
  `<input type="text" inputmode="decimal">`: the mobile keyboard still
  opens on digits, and the server decides what the text means with
  `PhoenixKit.Utils.Number.parse_decimal/2` — comma or dot, grouping
  spaces, sign, and nothing else.

  Otherwise it is `<.input>`: a `Phoenix.HTML.FormField` or raw
  `name`/`value`, `label`, gettext-translated `errors`, `class` on the
  control and `wrapper_class` on the `phx-feedback-for` wrapper, the
  required marker, and daisyUI 5 styling.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]

  alias PhoenixKit.Utils.Number

  @doc """
  Renders a free-decimal text control.

  The value is shown normalized when it is a number (`Decimal.new("2.500")`
  → `2.5`, `1E+3` → `1000`) and echoed back unchanged when it is a binary,
  so the text a person typed survives a re-render exactly as typed — a
  `2,5` does not turn into `2.5` under their cursor.

  ## Examples

      <%!-- FormField binding: name, id, value, errors derived --%>
      <.decimal_input field={@form[:quantity]} label="Quantity" />

      <%!-- Unit suffix inside the field --%>
      <.decimal_input field={@form[:weight]} label="Weight" unit="kg" />

      <%!-- Raw name/value for a row in a list, small and right-aligned --%>
      <.decimal_input
        id={"row-\#{row.id}-qty"}
        name="qty"
        value={row.qty}
        class="input-sm text-right"
        phx-debounce="400"
        phx-blur="commit_qty"
        phx-value-row_id={row.id}
      />

  Parse the submitted text with `PhoenixKit.Utils.Number.parse_decimal/2`:

      case Number.parse_decimal(params["qty"], min: 0) do
        {:ok, qty} -> ...
        {:error, :empty} -> ...
        {:error, _reason} -> ...
      end
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :unit, :string,
    default: nil,
    doc: "a unit suffix rendered inside the field, after the number (kg, m, pcs)"

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the control — daisyUI modifiers like `input-sm`, `input-primary`, or `text-right`"

  attr :wrapper_class, :any,
    default: nil,
    doc: "extra classes for the outer `<div phx-feedback-for>` wrapper"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:quantity]"

  attr :errors, :list, default: []

  attr :rest, :global,
    include: ~w(autofocus disabled form maxlength placeholder readonly required size)

  def decimal_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign(:value, if(assigns.value == nil, do: field.value, else: assigns.value))
    |> decimal_input()
  end

  def decimal_input(assigns) do
    assigns = assign(assigns, :text, Number.format_decimal(assigns.value))

    ~H"""
    <div phx-feedback-for={@name} class={@wrapper_class}>
      <label :if={@label && @label != ""} class="label mb-2" for={@id}>
        <span class="font-semibold">{@label}</span>
        <span :if={@rest[:required]} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>
      <%!-- Unit variant: daisyUI 5 puts the `input` class on a <label>
           wrapper so the suffix sits inside the field; the wrapper never
           receives focus, hence `focus-within`. --%>
      <label
        :if={@unit}
        class={[
          "input w-full transition-colors focus-within:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
      >
        <input
          type="text"
          inputmode="decimal"
          autocomplete="off"
          name={@name}
          id={@id}
          value={@text}
          class="grow min-w-0"
          {@rest}
        />
        <span class="opacity-60 select-none" aria-hidden="true">{@unit}</span>
      </label>
      <input
        :if={!@unit}
        type="text"
        inputmode="decimal"
        autocomplete="off"
        name={@name}
        id={@id}
        value={@text}
        class={[
          "input w-full transition-colors focus:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
