defmodule PhoenixKit.ThemeConfig do
  @moduledoc """
  Theme configuration module for PhoenixKit.

  This is a placeholder implementation that provides default values.
  """

  @doc """
  Returns true if theme system is enabled.
  """
  def theme_enabled?, do: false

  @doc """
  Returns the current theme.
  """
  def get_theme, do: "light"

  @doc """
  Returns theme data attributes for HTML elements.
  """
  def theme_data_attributes, do: [{"data-theme", "light"}]

  @doc """
  Returns modern CSS variables for theme system.
  """
  def modern_css_variables, do: "--theme: light"
end
