defmodule PhoenixKitWeb.Live.Modules.Entities.Hooks do
  @moduledoc """
  LiveView hooks for entity module pages.

  Provides common setup and subscriptions for all entity-related LiveViews.
  """

  import Phoenix.LiveView
  alias PhoenixKit.Entities.Events

  @doc """
  Subscribes to entity events when the LiveView is connected.

  Add this to your entity LiveView with:

      on_mount PhoenixKitWeb.Live.Modules.Entities.Hooks

  This automatically subscribes to entity creation, update, and deletion events.
  """
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_to_entities()
    end

    {:cont, socket}
  end
end
