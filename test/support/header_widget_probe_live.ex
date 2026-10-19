defmodule PhoenixKitWeb.Test.HeaderWidgetProbeLive do
  @moduledoc """
  Stand-in for a module's header widget (`PhoenixKit.Module.header_widgets/0`): a LiveView
  that prints the session its session function built, so a test can see what reached it.

  Not routed; it is only ever rendered by the admin layout as a sticky nested LiveView,
  backing test/integration/phoenix_kit_web/live/header_widgets_test.exs.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, :session, session), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span
      class="header-widget-probe"
      data-user={@session["user_uuid"]}
      data-locale={@session["locale"]}
    >
      widget {@session["label"]}
    </span>
    """
  end
end
