defmodule PhoenixKitWeb.Components.Core.Checkbox do
  @moduledoc """
  Provides a default checkbox UI component.

  daisyUI's `.checkbox` class only styles the `<input>` — it does not wrap it
  in a `<label>`, so a hand-rolled checkbox + adjacent text is easy to get
  wrong (clicking the text does nothing). This component always renders the
  correct `<label><input/><span>...</span></label>` structure, plus the
  hidden-false fallback input so an unchecked box still submits a value.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders a checkbox.

  ## Examples

      <.checkbox field={@form[:remember_me]} label="Keep me logged in" />

      <.checkbox
        name="settings[allow_registration]"
        checked={@settings["allow_registration"] == "true"}
        label="Anyone can register"
      />

      <%!-- Rich label content (badges, icons) via the default slot —
           overrides the `label` attr when given: --%>
      <.checkbox name="roles[admin]" checked={...} disabled={owner_role?}>
        <.role_badge role={role} size={:sm} /> {role.name}
        <:description>Grants full administrative access</:description>
      </.checkbox>

      <%!-- Locked (but still submitted) while a parent switch is off — use
           `wrapper_class`, not `disabled`, so the field's real stored value
           keeps submitting instead of collapsing to the hidden "false"
           fallback: --%>
      <.checkbox
        name="settings[oauth_google_enabled]"
        checked={@settings["oauth_google_enabled"] == "true"}
        label="Google Sign-In"
        wrapper_class={!@settings["oauth_enabled"] == "true" && "pointer-events-none"}
      />
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
  attr :disabled, :boolean, default: false

  attr :title, :string,
    default: nil,
    doc:
      "tooltip on the wrapping `<label>` (covers the box and the text), e.g. explaining why a checkbox is disabled"

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the `<input type=\"checkbox\">` (e.g. `checkbox-sm`, `checkbox-accent`)"

  attr :wrapper_class, :any,
    default: nil,
    doc:
      "extra classes merged onto the wrapping `<label>` (e.g. spacing like `mb-3`, or `pointer-events-none` to lock the whole control — box and text — without excluding it from form submission the way `disabled` would)."

  attr :rest, :global, include: ~w(readonly required)

  slot :inner_block,
    doc: "Rich label content (badges, icons, multiple elements). Overrides `label` when given."

  slot :description, doc: "Secondary helper text rendered below the label."

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
      <% has_description? = @description != [] %>
      <label
        title={@title}
        class={[
          "flex gap-4 text-sm leading-6 text-base-content",
          (has_description? && "items-start") || "items-center",
          (@disabled && "cursor-not-allowed opacity-70") || "cursor-pointer",
          @wrapper_class
        ]}
      >
        <input type="hidden" name={@name} value="false" />

        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          disabled={@disabled}
          class={["checkbox checkbox-primary", has_description? && "mt-0.5", @class]}
          {@rest}
        />

        <span class="select-none">
          <span class={has_description? && "font-medium"}>
            <%= if @inner_block != [] do %>
              {render_slot(@inner_block)}
            <% else %>
              {@label}
            <% end %>
          </span>
          <span :if={has_description?} class="block text-xs text-base-content/60">
            {render_slot(@description)}
          </span>
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
