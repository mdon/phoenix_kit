defmodule PhoenixKitWeb.Router do
  @moduledoc """
  PhoenixKit library router.

  This router is used only for development and testing purposes.
  In production, parent applications should use `phoenix_kit_routes()` macro
  to integrate PhoenixKit routes into their own router.

  ## Usage in Parent Application

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import PhoenixKitWeb.Integration

        # Add PhoenixKit routes
        phoenix_kit_routes()
      end
  """
  use PhoenixKitWeb, :router

  import PhoenixKitWeb.Integration
  import PhoenixKitWeb.Users.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_phoenix_kit_current_user
  end

  # PhoenixKit routes - main integration point
  phoenix_kit_routes()

  # Note: This is a library module - parent applications should:
  # 1. Use phoenix_kit_routes() macro in their own router
  # 2. Provide their own home page routes
  # 3. Configure their own LiveDashboard if needed
  # 4. Handle their own API routes
end
