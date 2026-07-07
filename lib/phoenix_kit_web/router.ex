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
    plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_session_uuid
    plug :fetch_phoenix_kit_current_user
  end

  # PhoenixKit routes - main integration point
  phoenix_kit_routes()

  # Test-only: a routable stand-in for a host app's own public LiveView,
  # backing test/phoenix_kit_web/users/auth_seo_no_index_test.exs. Needs a
  # real route (not live_isolated/3) because :phoenix_kit_mount_current_scope
  # attaches a :handle_params hook that requires a non-nil socket.router.
  if Mix.env() == :test do
    scope "/", PhoenixKitWeb.Test do
      pipe_through :browser

      live "/__test/seo-no-index-probe", PublicHostAppLive
    end
  end

  defp ensure_session_uuid(conn, _opts) do
    case Plug.Conn.get_session(conn, :phoenix_kit_session_uuid) do
      nil ->
        Plug.Conn.put_session(conn, :phoenix_kit_session_uuid, UUIDv7.generate())

      _ ->
        conn
    end
  end

  # Note: This is a library module - parent applications should:
  # 1. Use phoenix_kit_routes() macro in their own router
  # 2. Provide their own home page routes
  # 3. Configure their own LiveDashboard if needed
  # 4. Handle their own API routes
end
