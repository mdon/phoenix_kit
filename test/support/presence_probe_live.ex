defmodule PhoenixKitWeb.Test.PresenceProbeLive do
  @moduledoc """
  Stand-in for a host app's own public LiveView, mounted through
  `:phoenix_kit_mount_current_scope` — same shape as `PublicHostAppLive` — but
  routed with a dynamic `:page` segment so a test can `push_patch` between two
  distinct paths inside the same live_session. That is the one thing
  `PublicHostAppLive`'s single static route cannot exercise: presence's
  per-navigation `current_page` tracking needs a URL that actually changes
  without a remount.

  Routed only in Mix.env() == :test (see PhoenixKitWeb.Router); backs
  test/integration/users/live_sessions_presence_test.exs.
  """
  use Phoenix.LiveView

  on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}

  # Required for `render_patch/2` in the presence test: a client-initiated
  # "live_patch" event dispatches straight to `view.handle_params/3` without
  # checking whether the view exports it (unlike the initial mount path,
  # which checks and skips the call when it doesn't) — omitting this raises
  # UndefinedFunctionError the moment a test patches to a second path.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="presence-probe" data-url-path={assigns[:url_path]}></div>
    """
  end
end
