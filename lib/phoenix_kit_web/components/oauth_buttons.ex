defmodule PhoenixKitWeb.Components.OAuthButtons do
  @moduledoc """
  OAuth authentication buttons component for Google and Apple Sign-In.

  This component automatically checks if OAuth is available and configured.
  If OAuth is not available (dependencies not installed or not enabled in settings),
  the buttons will not be rendered.
  """

  use Phoenix.Component
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes

  @doc """
  Renders OAuth provider buttons for authentication.

  This component only renders buttons if:
  - OAuth is enabled in settings (oauth_enabled = true)
  - Ueberauth library is loaded
  - At least one provider is configured

  ## Examples

      <.oauth_buttons />
      <.oauth_buttons show_divider={false} />
      <.oauth_buttons class="mt-6" />
  """
  attr :class, :string, default: ""
  attr :show_divider, :boolean, default: true

  def oauth_buttons(assigns) do
    # Check each provider individually
    assigns =
      assigns
      |> assign(:google_enabled, OAuthAvailability.provider_enabled?(:google))
      |> assign(:apple_enabled, OAuthAvailability.provider_enabled?(:apple))
      |> assign(:github_enabled, OAuthAvailability.provider_enabled?(:github))

    # Check if at least one provider is enabled
    any_provider_enabled =
      assigns.google_enabled or assigns.apple_enabled or assigns.github_enabled

    assigns = assign(assigns, :any_provider_enabled, any_provider_enabled)

    ~H"""
    <%= if @any_provider_enabled do %>
      <div class={@class}>
        <%= if @show_divider do %>
          <div class="divider text-base-content/60">Or continue with</div>
        <% end %>

        <div class="space-y-2">
          <%!-- Google Sign-In Button --%>
          <%= if @google_enabled do %>
            <.link
              href={Routes.path("/users/auth/google")}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <.icon_google class="w-5 h-5" />
              <span>Continue with Google</span>
            </.link>
          <% end %>
          <%!-- Apple Sign-In Button --%>
          <%= if @apple_enabled do %>
            <.link
              href={Routes.path("/users/auth/apple")}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <.icon_apple class="w-5 h-5" />
              <span>Continue with Apple</span>
            </.link>
          <% end %>
          <%!-- GitHub Sign-In Button --%>
          <%= if @github_enabled do %>
            <.link
              href={Routes.path("/users/auth/github")}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <.icon_github class="w-5 h-5" />
              <span>Continue with GitHub</span>
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Google icon SVG.
  """
  attr :class, :string, default: ""

  def icon_google(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} xmlns="http://www.w3.org/2000/svg">
      <path
        fill="#4285F4"
        d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
      />
      <path
        fill="#34A853"
        d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
      />
      <path
        fill="#FBBC05"
        d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
      />
      <path
        fill="#EA4335"
        d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
      />
    </svg>
    """
  end

  @doc """
  Apple icon SVG.
  """
  attr :class, :string, default: ""

  def icon_apple(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} xmlns="http://www.w3.org/2000/svg" fill="currentColor">
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
    """
  end

  @doc """
  GitHub icon SVG.
  """
  attr :class, :string, default: ""

  def icon_github(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} xmlns="http://www.w3.org/2000/svg" fill="currentColor">
      <path d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.34-3.369-1.34-.454-1.156-1.11-1.463-1.11-1.463-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z" />
    </svg>
    """
  end
end
