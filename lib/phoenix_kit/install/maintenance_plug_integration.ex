defmodule PhoenixKit.Install.MaintenancePlugIntegration do
  use PhoenixKit.Install.IgniterCompat

  @moduledoc """
  Handles automatic integration of the MaintenanceMode plug into the browser pipeline.

  This module provides functionality to:
  - Find the :browser pipeline in the Phoenix router
  - Add the PhoenixKitWeb.Plugs.MaintenanceMode plug automatically using Igniter's built-in helpers
  - Handle cases where the plug already exists (idempotent)
  """

  alias Igniter.Libs.Phoenix, as: IgniterPhoenix

  @doc """
  Adds the MaintenanceMode plug to the :browser pipeline in the Phoenix router.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with maintenance plug integrated or warning if router not found.
  """
  def add_maintenance_plug_to_browser_pipeline(igniter) do
    case IgniterPhoenix.select_router(igniter) do
      {igniter, nil} ->
        # No router found, add warning
        Igniter.add_warning(
          igniter,
          "Could not find router to add MaintenanceMode plug. Please add 'plug PhoenixKitWeb.Plugs.MaintenanceMode' to your :browser pipeline manually."
        )

      {igniter, router_module} ->
        # Use Igniter's built-in append_to_pipeline function
        IgniterPhoenix.append_to_pipeline(
          igniter,
          :browser,
          "plug PhoenixKitWeb.Plugs.MaintenanceMode",
          router: router_module
        )
    end
  end
end
