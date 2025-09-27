defmodule PhoenixKitWeb.Components.Core.FormFieldError do
  @moduledoc """
  Provides an error UI component for form components.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-2 flex gap-2 text-sm text-error phx-no-feedback:hidden">
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end
end
