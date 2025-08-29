defmodule PhoenixKitWeb.AuthRouter do
  @moduledoc """
  Legacy authentication router for PhoenixKit.

  **DEPRECATED**: This module is kept for backward compatibility.
  Use `PhoenixKitWeb.Integration.phoenix_kit_routes/1` macro instead.

  This router provides basic forwarding to authentication routes but lacks
  the advanced features and proper pipeline configuration of the Integration module.

  ## Migration Path

  Replace usage of this router with the Integration macro:

      # Instead of:
      forward "/auth", PhoenixKitWeb.AuthRouter

      # Use:
      import PhoenixKitWeb.Integration
      phoenix_kit_routes("/auth")
  """
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
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

  pipeline :phoenix_kit_redirect_if_authenticated do
    plug PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_user_is_authenticated
  end

  pipeline :require_authenticated do
    plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_authenticated_user
  end

  scope "/" do
    pipe_through [:browser, :phoenix_kit_redirect_if_authenticated]

    # Test LiveView routes moved to integration.ex for proper parent app support

    # LiveView routes for authentication
    live "/register", PhoenixKitWeb.Users.RegistrationLive, :new
    live "/log_in", PhoenixKitWeb.Users.LoginLive, :new

    post "/log_in", PhoenixKitWeb.Users.SessionController, :create

    live "/reset_password", PhoenixKitWeb.Users.ForgotPasswordLive, :new
    live "/reset_password/:token", PhoenixKitWeb.Users.ResetPasswordLive, :edit
  end

  scope "/" do
    pipe_through [:browser]

    delete "/log_out", PhoenixKitWeb.Users.SessionController, :delete
    get "/log_out", PhoenixKitWeb.Users.SessionController, :get_logout

    live "/confirm/:token", PhoenixKitWeb.Users.ConfirmationLive, :edit
    live "/confirm", PhoenixKitWeb.Users.ConfirmationInstructionsLive, :new
  end

  scope "/" do
    pipe_through [:browser, :require_authenticated]

    live "/settings", PhoenixKitWeb.Users.SettingsLive, :edit
    live "/settings/confirm_email/:token", PhoenixKitWeb.Users.SettingsLive, :confirm_email
  end
end
