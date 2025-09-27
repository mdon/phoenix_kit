defmodule PhoenixKitWeb.Components.Core.Checkbox do
  @moduledoc """
  Provides a default checkbox UI component.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders a checkbox.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :errors, :list, default: []
  attr :checked, :boolean, default: false

  attr :rest, :global, include: ~w(readonly required)

  slot :inner_block

  def checkbox(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label class="flex items-center gap-4 text-sm leading-6 text-base-content">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="checkbox checkbox-primary"
          {@rest}
        />
        <span class="select-none cursor-pointer">
          {@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
