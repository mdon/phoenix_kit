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

  Be clear-eyed about what that costs. The popup navigates on to the
  provider's consent page, and `window.opener` survives navigation — so
  the provider's origin holds a live (cross-origin) reference to your
  window. The same-origin policy limits it to `opener.location = …`,
  `postMessage`, `close()` and `focus()`, but the first of those is
  reverse tabnabbing: a compromised or open-redirect-chained provider
  page can navigate the tab behind the popup.

  `href` is still required to be a local path — that stops the reference
  being handed straight to an arbitrary origin, and keeps the flow
  starting on a route you control — but it is not what makes the popup
  safe once the provider takes over. If your threat model includes the
  provider, send `Cross-Origin-Opener-Policy: same-origin-allow-popups`
  on the opener page and have the callback `postMessage` back (with an
  origin check) instead of touching `opener.location`.

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
    default: nil,
    doc:
      "Popup window name. Defaults to one derived from `href`, so two buttons on " <>
        "a page (Connect Google / Connect Shelly) get distinct windows AND distinct " <>
        "DOM ids without configuration. Sharing a name reuses the same window."

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

    assigns = assign_new(assigns, :resolved_window_name, fn -> window_name(assigns) end)

    ~H"""
    <a
      href={@href}
      id={@id || derived_id(@resolved_window_name)}
      phx-hook="PopupLink"
      data-window-name={@resolved_window_name}
      data-window-width={@window_width}
      data-window-height={@window_height}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  # A fixed default meant every unconfigured button on a page shared one id —
  # invalid HTML, and phx-hook requires uniqueness. The start route is already
  # required to be local and is naturally distinct per provider, so it makes a
  # better default than a constant.
  defp window_name(%{window_name: name}) when is_binary(name) and name != "", do: name
  defp window_name(%{href: href}), do: "oauth-connect-" <> slug(href)

  # An id derived from a free-form window name has to survive being used as a
  # DOM id and inside `querySelector` — a name with spaces or quotes would
  # produce an id LiveView cannot look the element up by.
  defp derived_id(window_name) do
    case slug(window_name) do
      "" -> "pk-connect"
      slug -> "pk-connect-" <> slug
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
