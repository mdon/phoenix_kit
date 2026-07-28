defmodule PhoenixKitWeb.Components.Core.ConnectAccountButton do
  @moduledoc """
  A "Connect your X account" button that runs an OAuth authorization in
  a popup window — the Google-login-style pattern for third-party
  integrations (distinct from `OAuthProvider`, which handles *sign-in*
  to the app itself).

  Flow contract:

    1. The button opens `href` in a named popup (the app's OAuth start
       route, which redirects to the provider's consent page).
    2. The provider redirects back to the app's callback route inside
       the popup; the callback completes the exchange server-side.
    3. The callback page should refresh the opener and close itself:

           <script>
             if (window.opener) { window.opener.location.reload(); }
             setTimeout(function () { window.close(); }, 4000);
           </script>

  Falls back to normal navigation when popups are blocked (the plain
  `href` still works full-page).

  Origin: extracted from NordSwitch's Shelly account connect flow;
  intended for any Integrations-system OAuth (Google, Stripe, …).
  """

  use Phoenix.Component

  @doc """
  Renders the connect-account popup button.

  ## Examples

      <.connect_account_button href="/shelly/oauth/start">
        ⚡ Connect Shelly account
      </.connect_account_button>

      <.connect_account_button href={~p"/integrations/google/start"} class="btn btn-outline btn-sm">
        Connect Google
      </.connect_account_button>
  """
  attr :href, :string, required: true, doc: "The app's OAuth start route"
  attr :window_name, :string, default: "oauth-connect", doc: "Popup window name"
  attr :window_width, :integer, default: 480
  attr :window_height, :integer, default: 680
  attr :class, :string, default: "btn btn-primary btn-sm"
  attr :rest, :global

  slot :inner_block, required: true

  def connect_account_button(assigns) do
    ~H"""
    <a
      href={@href}
      onclick={"window.open(this.href, '#{@window_name}', 'width=#{@window_width},height=#{@window_height}'); return false;"}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end
end
