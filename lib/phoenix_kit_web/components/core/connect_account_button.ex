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
    3. The callback page refreshes the opener and closes itself — see
       "Callback page" below.

  ## Progressive enhancement

  This renders a real `<a href>`, and the popup is opened by the
  `ConnectAccountPopup` JS hook rather than an inline `onclick` (the kit
  removed inline handlers everywhere for CSP). The click is intercepted
  *only after* `window.open` actually returns a window, so **a blocked
  popup, JS being off, or a modifier-click all fall back to ordinary
  navigation** and the flow still completes full-page. The previous
  inline version ended every click with `return false`, which cancelled
  navigation even when the popup never opened — the button did nothing.

  Host wiring: the hook ships in core's `phoenix_kit.js`, which hosts
  already load and spread into their LiveSocket (`mix phoenix_kit.install`
  wires this). No per-app JS.

  ## Callback page

  The popup hands control back to the opener. On the callback page:

      <script>
        if (window.opener && !window.opener.closed) {
          window.opener.location.reload();
        }
        window.close();
      </script>

  The popup is deliberately **not** `rel="noopener"`: `window.opener` is
  exactly what the callback needs in order to refresh the page behind it.
  That is safe because `href` is your own OAuth start route — this
  component only accepts a local path, so the opener reference is never
  handed to a third-party origin.

  Origin: extracted from NordSwitch's Shelly account connect flow;
  intended for any Integrations-system OAuth (Google, Stripe, …).
  """

  use Phoenix.Component

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders the connect-account popup button.

  ## Examples

      <.connect_account_button href="/shelly/oauth/start">
        Connect Shelly account
      </.connect_account_button>

      <.connect_account_button
        href={~p"/integrations/google/start"}
        class="btn btn-outline btn-sm"
        window_name="google-connect"
      >
        Connect Google
      </.connect_account_button>
  """
  attr :href, :string,
    required: true,
    doc:
      "The app's OAuth start route. Must be a local path — the popup keeps its " <>
        "`window.opener`, so it is never pointed at a third-party origin."

  attr :window_name, :string,
    default: "oauth-connect",
    doc:
      "Popup window name. Sharing one name across buttons reuses the same window; " <>
        "give concurrent flows distinct names."

  attr :window_width, :integer, default: 480
  attr :window_height, :integer, default: 680
  attr :class, :any, default: "btn btn-primary btn-sm"

  attr :id, :string,
    default: nil,
    doc:
      "DOM id. A phx-hook element MUST have one, so it defaults to the window " <>
        "name — pass an explicit id when two buttons share a window name."

  attr :rest, :global, doc: "Extra attributes for the anchor (aria-*, data-*, …)"

  slot :inner_block, required: true

  def connect_account_button(assigns) do
    unless Routes.local_path?(assigns.href) do
      raise ArgumentError, """
      connect_account_button expects a local path for :href, got: #{inspect(assigns.href)}

      The popup deliberately retains `window.opener` so the OAuth callback can
      refresh the page behind it. Pointing it at another origin would hand that
      reference to a third party. Link to your own OAuth start route, which
      redirects on to the provider.
      """
    end

    ~H"""
    <a
      href={@href}
      id={@id || derived_id(@window_name)}
      phx-hook="ConnectAccountPopup"
      data-window-name={@window_name}
      data-window-width={@window_width}
      data-window-height={@window_height}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  # An id derived from a free-form window name has to survive being used as a
  # DOM id and inside `querySelector` — a name with spaces or quotes would
  # produce an id LiveView cannot look the element up by.
  defp derived_id(window_name) do
    slug =
      window_name
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
      |> String.trim("-")

    if slug == "", do: "pk-connect", else: "pk-connect-" <> slug
  end
end
