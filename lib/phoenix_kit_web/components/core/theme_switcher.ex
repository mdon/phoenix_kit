defmodule PhoenixKitWeb.Components.Core.ThemeSwitcher do
  @moduledoc """
  Provides a theme switcher UI component.
  """

  use Phoenix.Component

  @doc """
  Renders a simple theme switcher placeholder.

  Note: This is a placeholder implementation. The full theme system
  requires the PhoenixKit.ThemeConfig module to be implemented.
  """
  attr :size, :string, default: "medium", values: ["small", "medium", "large"]
  attr :show_label, :boolean, default: true
  attr :class, :string, default: nil
  attr :rest, :global

  def theme_switcher(assigns) do
    ~H"""
    <%!-- Theme switcher placeholder - ThemeConfig module not implemented --%>
    <div class={["theme-switcher-placeholder", @class]} {@rest}>
      <span :if={@show_label} class="text-sm text-gray-500">Theme: Default</span>
      <span :if={!@show_label} class="w-4 h-4 text-gray-400">🎨</span>
    </div>
    """
  end
end
