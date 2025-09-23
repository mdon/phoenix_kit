defmodule PhoenixKitWeb.Components.Core.Icon do
  @moduledoc """
  Provides a hero icon UI component.
  """

  use Phoenix.Component

  @doc """
  Renders an icon.
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
