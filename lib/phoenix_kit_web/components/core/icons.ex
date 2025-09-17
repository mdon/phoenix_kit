defmodule PhoenixKitWeb.Components.Core.Icons do
  @moduledoc """
  Provides icons for other components and interfaces.
  """
  use Phoenix.Component

  @doc """
  A component for an arrow to left.
  """
  def icon_arrow_left(assigns) do
    ~H"""
    <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 19l-7-7m0 0l7-7m-7 7h18"
      >
      </path>
    </svg>
    """
  end
end
