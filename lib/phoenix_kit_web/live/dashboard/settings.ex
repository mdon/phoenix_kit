defmodule PhoenixKitWeb.Live.Dashboard.Settings do
  @moduledoc """
  Compatibility redirect for the retired `/dashboard/settings` page.

  The account UI now lives at `/profile/settings`
  (`PhoenixKitWeb.Live.Users.ProfileSettings`) — see that module for why it
  moved off the dashboard. This route stays registered because the old path
  is still out in the world: host-app links, bookmarks, and the
  confirm-email URLs inside change-email messages that were delivered before
  the move.

  Both clauses `push_navigate` rather than render. The token clause carries
  its token to the new confirm-email route instead of spending it here, so
  there is exactly one place that consumes a change-email token.

  Nothing is rendered: `push_navigate/2` from `mount/3` redirects before the
  first paint, so `render/1` is never reached.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok, push_navigate(socket, to: Routes.path("/profile/settings/confirm-email/#{token}"))}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: Routes.user_settings_path())}
  end

  @impl Phoenix.LiveView
  def render(assigns), do: ~H""
end
