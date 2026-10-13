defmodule PhoenixKitWeb.Test.AdminLayoutProbeLive do
  @moduledoc """
  Stand-in for a host or plugin LiveView that does its OWN gating and only
  wants the admin chrome: mounted through
  `{PhoenixKitWeb.Users.Auth, :phoenix_kit_admin_layout}` and nothing else, with
  no `layout:` of its own and no `LayoutWrapper` in its markup.

  It lives in the `PhoenixKitWeb.*` namespace on purpose: that is the namespace
  `:phoenix_kit_ensure_admin` treats as a core view (no layout rewrite, and a
  permission-mapping check it would fail), so a layout arriving here can only
  have come from the explicit hook.

  Routed only in Mix.env() == :test (see PhoenixKitWeb.Router), under the
  `/admin` segment so the layout draws its chrome; backs
  test/integration/phoenix_kit_web/live/admin_layout_on_mount_test.exs.
  """
  use Phoenix.LiveView

  on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_admin_layout}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="admin-layout-probe">probe body</div>
    """
  end
end
