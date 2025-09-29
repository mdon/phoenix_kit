defmodule PhoenixKitWeb.Integration do
  @moduledoc """
  Integration helpers for adding PhoenixKit to Phoenix applications.

  ## Basic Usage

  Add to your router:

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import PhoenixKitWeb.Integration

        # Add PhoenixKit routes
        phoenix_kit_routes()  # Default: /phoenix_kit prefix
      end

  ## Layout Integration

  Configure parent layouts in config.exs:

      config :phoenix_kit,
        repo: MyApp.Repo,
        layout: {MyAppWeb.Layouts, :app},
        root_layout: {MyAppWeb.Layouts, :root}

  ## Authentication Callbacks

  Use in your app's live_sessions:

  - `:phoenix_kit_mount_current_scope` - Mounts user and scope (recommended)
  - `:phoenix_kit_ensure_authenticated_scope` - Requires authentication
  - `:phoenix_kit_redirect_if_authenticated_scope` - Redirects if logged in

  ## Routes Created

  Authentication routes:
  - /users/register, /users/log-in, /users/magic-link
  - /users/settings, /users/reset-password, /users/confirm
  - /users/log-out (GET/DELETE)

  Admin routes (Owner/Admin only):
  - /admin/dashboard, /admin/users, /admin/users/roles
  - /admin/users/live_sessions, /admin/users/sessions
  - /admin/settings, /admin/modules

  ## DaisyUI Setup

  1. Install: `npm install daisyui@latest`
  2. Add to tailwind.config.js:
     - Content: `"../../deps/phoenix_kit"`
     - Plugin: `require('daisyui')`

  ## Layout Templates

  Use `{@inner_content}` not `render_slot(@inner_block)`:

      <%!-- Correct --%>
      <main>{@inner_content}</main>

  ## Scope Usage in Templates

      <%= if PhoenixKit.Users.Auth.Scope.authenticated?(@phoenix_kit_current_scope) do %>
        Welcome, {PhoenixKit.Users.Auth.Scope.user_email(@phoenix_kit_current_scope)}!
      <% end %>

  """

  @doc """
  Creates locale-aware routing scopes based on enabled languages.

  This macro generates both a localized scope (e.g., `/en/`) and a non-localized
  scope for backward compatibility. The locale pattern is dynamically generated
  from the database-stored enabled language codes.

  ## Examples

      locale_scope do
        live "/admin/dashboard", DashboardLive, :index
      end

      # Generates routes like:
      # /phoenix_kit/en/admin/dashboard (with locale)
      # /phoenix_kit/admin/dashboard (without locale, defaults to "en")
  """
  defmacro locale_scope(opts \\ [], do: block) do
    # Get URL prefix at compile time
    raw_prefix =
      try do
        PhoenixKit.Config.get_url_prefix()
      rescue
        _ -> "/phoenix_kit"
      end

    url_prefix =
      case raw_prefix do
        "" -> "/"
        prefix -> prefix
      end

    quote do
      # Get enabled locales at compile time with fallback
      enabled_locales =
        try do
          PhoenixKit.Module.Languages.enabled_locale_codes()
        rescue
          # Fallback if module not available at compile time
          _ -> ["en"]
        end

      # Create regex pattern for enabled locales
      pattern = Enum.join(enabled_locales, "|")

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end

      # Localized scope with locale parameter
      scope "#{unquote(url_prefix)}/:locale",
            PhoenixKitWeb,
            Keyword.put(unquote(opts), :locale, ~r/^(#{pattern})$/) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        unquote(block)
      end

      # Non-localized scope for backward compatibility (defaults to "en")
      scope unquote(url_prefix), PhoenixKitWeb, unquote(opts) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        unquote(block)
      end
    end
  end

  defmacro phoenix_kit_routes do
    # Get URL prefix at compile time and handle empty string case for router compatibility
    raw_prefix =
      try do
        PhoenixKit.Config.get_url_prefix()
      rescue
        # Fallback if config not available at compile time
        _ -> "/phoenix_kit"
      end

    url_prefix =
      case raw_prefix do
        "" -> "/"
        prefix -> prefix
      end

    quote do
      # Define the auto-setup pipeline
      pipeline :phoenix_kit_auto_setup do
        plug PhoenixKitWeb.Integration, :phoenix_kit_auto_setup
      end

      pipeline :phoenix_kit_redirect_if_authenticated do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_user_is_authenticated
      end

      pipeline :phoenix_kit_require_authenticated do
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_authenticated_user
      end

      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        post "/users/log-in", Users.SessionController, :create
        delete "/users/log-out", Users.SessionController, :delete
        get "/users/log-out", Users.SessionController, :get_logout
        get "/users/magic-link/:token", Users.MagicLinkController, :verify

        # Email webhook endpoint (no authentication required)
        post "/webhooks/email", Controllers.EmailWebhookController, :handle
      end

      # Email export routes (require admin authentication)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        get "/admin/emails/export", Controllers.EmailExportController, :export_logs
        get "/admin/emails/metrics/export", Controllers.EmailExportController, :export_metrics
        get "/admin/emails/blocklist/export", Controllers.EmailExportController, :export_blocklist
        get "/admin/emails/:id/export", Controllers.EmailExportController, :export_email_details
      end

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end

      # Get enabled locales at compile time with fallback
      enabled_locales =
        try do
          PhoenixKit.Module.Languages.enabled_locale_codes()
        rescue
          # Fallback if module not available at compile time
          _ -> ["en"]
        end

      # Create regex pattern for enabled locales
      pattern = Enum.join(enabled_locales, "|")

      # Localized scope with locale parameter
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb, locale: ~r/^(#{pattern})$/ do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        live_session :phoenix_kit_redirect_if_user_is_authenticated_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
          # live "/test", TestLive, :index  # Moved to require_authenticated section
          live "/users/register", Users.RegistrationLive, :new
          live "/users/log-in", Users.LoginLive, :new
          live "/users/magic-link", Users.MagicLinkLive, :new
          live "/users/reset-password", Users.ForgotPasswordLive, :new
          live "/users/reset-password/:token", Users.ResetPasswordLive, :edit
        end

        live_session :phoenix_kit_current_user_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/users/confirm/:token", Users.ConfirmationLive, :edit
          live "/users/confirm", Users.ConfirmationInstructionsLive, :new
        end

        live_session :phoenix_kit_require_authenticated_user_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/users/settings", Users.SettingsLive, :edit
          live "/users/settings/confirm-email/:token", Users.SettingsLive, :confirm_email
        end

        live_session :phoenix_kit_admin_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/dashboard", Live.DashboardLive, :index
          live "/admin", Live.DashboardLive, :index
          live "/admin/users", Live.Users.UsersLive, :index
          live "/admin/users/new", Users.UserFormLive, :new
          live "/admin/users/edit/:id", Users.UserFormLive, :edit
          live "/admin/users/roles", Live.Users.RolesLive, :index
          live "/admin/users/live_sessions", Live.Users.LiveSessionsLive, :index
          live "/admin/users/sessions", Live.Users.SessionsLive, :index
          live "/admin/settings", Live.SettingsLive, :index
          live "/admin/modules", Live.ModulesLive, :index
          live "/admin/settings/referral-codes", Live.Modules.ReferralCodesLive, :index
          live "/admin/settings/email-tracking", Live.Modules.EmailTrackingLive, :index
          live "/admin/settings/languages", Live.Modules.LanguagesLive, :index
          live "/admin/users/referral-codes", Live.Users.ReferralCodesLive, :index
          live "/admin/users/referral-codes/new", Live.Users.ReferralCodeFormLive, :new
          live "/admin/users/referral-codes/edit/:id", Live.Users.ReferralCodeFormLive, :edit
          live "/admin/emails/dashboard", Live.EmailTracking.EmailMetricsLive, :index
          live "/admin/emails", Live.EmailTracking.EmailLogsLive, :index
          live "/admin/emails/email/:id", Live.EmailTracking.EmailDetailsLive, :show
          live "/admin/emails/queue", Live.EmailTracking.EmailQueueLive, :index
          live "/admin/emails/blocklist", Live.EmailTracking.EmailBlocklistLive, :index
        end
      end

      # Non-localized scope for backward compatibility (defaults to "en")
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        live_session :phoenix_kit_redirect_if_user_is_authenticated,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
          # live "/test", TestLive, :index  # Moved to require_authenticated section
          live "/users/register", Users.RegistrationLive, :new
          live "/users/log-in", Users.LoginLive, :new
          live "/users/magic-link", Users.MagicLinkLive, :new
          live "/users/reset-password", Users.ForgotPasswordLive, :new
          live "/users/reset-password/:token", Users.ResetPasswordLive, :edit
        end

        live_session :phoenix_kit_current_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/users/confirm/:token", Users.ConfirmationLive, :edit
          live "/users/confirm", Users.ConfirmationInstructionsLive, :new
        end

        live_session :phoenix_kit_require_authenticated_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/users/settings", Users.SettingsLive, :edit
          live "/users/settings/confirm-email/:token", Users.SettingsLive, :confirm_email
        end

        live_session :phoenix_kit_admin,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/dashboard", Live.DashboardLive, :index
          live "/admin", Live.DashboardLive, :index
          live "/admin/users", Live.Users.UsersLive, :index
          live "/admin/users/new", Users.UserFormLive, :new
          live "/admin/users/edit/:id", Users.UserFormLive, :edit
          live "/admin/users/roles", Live.Users.RolesLive, :index
          live "/admin/users/live_sessions", Live.Users.LiveSessionsLive, :index
          live "/admin/users/sessions", Live.Users.SessionsLive, :index
          live "/admin/settings", Live.SettingsLive, :index
          live "/admin/modules", Live.ModulesLive, :index
          live "/admin/settings/referral-codes", Live.Modules.ReferralCodesLive, :index
          live "/admin/settings/emails", Live.Modules.EmailSystemLive, :index
          live "/admin/settings/languages", Live.Modules.LanguagesLive, :index
          live "/admin/users/referral-codes", Live.Users.ReferralCodesLive, :index
          live "/admin/users/referral-codes/new", Live.Users.ReferralCodeFormLive, :new
          live "/admin/users/referral-codes/edit/:id", Live.Users.ReferralCodeFormLive, :edit
          live "/admin/emails/dashboard", Live.EmailSystem.EmailMetricsLive, :index
          live "/admin/emails", Live.EmailSystem.EmailLogsLive, :index
          live "/admin/emails/email/:id", Live.EmailSystem.EmailDetailsLive, :show
          live "/admin/emails/queue", Live.EmailSystem.EmailQueueLive, :index
          live "/admin/emails/blocklist", Live.EmailSystem.EmailBlocklistLive, :index

          # Email Templates Management
          live "/admin/emails/templates", Live.EmailSystem.EmailTemplatesLive, :index
          live "/admin/emails/templates/new", Live.EmailSystem.EmailTemplateEditorLive, :new
          live "/admin/emails/templates/:id/edit", Live.EmailSystem.EmailTemplateEditorLive, :edit
        end
      end
    end
  end

  def init(opts) do
    opts
  end

  def call(conn, :phoenix_kit_auto_setup) do
    # Add backward compatibility for layouts that use render_slot(@inner_block)
    Plug.Conn.assign(conn, :inner_block, [])
  end
end
