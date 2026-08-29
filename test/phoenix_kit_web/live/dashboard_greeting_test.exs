defmodule PhoenixKitWeb.Live.DashboardGreetingTest do
  @moduledoc """
  `mount/3` runs twice per page load — once disconnected (the HTTP render),
  once connected (the websocket takeover) — and a value picked fresh on both
  passes visibly changes the instant the socket connects. `pick_greeting/1`
  is `Enum.random/1` over a dozen-odd keys, so that reroll was not a rare
  edge case: it happened on almost every page load.

  DB-free, mirrors `DashboardModuleRefreshTest`'s hand-built `%Socket{}`
  pattern: `connected?/1` reads only `transport_pid`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Live.Dashboard

  # A connected mount also runs `Overview.assign_overview/3`'s presence
  # tracking, which needs the host app's `PhoenixKit.Admin.Presence` process —
  # not present in this bare unit test, same reason
  # `DashboardModuleRefreshTest` only ever builds a disconnected socket. The
  # regression this file pins (no reroll between the two mount passes) only
  # needs the disconnected side to prove `greeting_key_for_mount/1` stopped
  # calling `pick_greeting/1` there.
  defp disconnected_socket do
    scope = %Scope{
      user: %User{uuid: "0193a5e4-0000-7000-8000-0000000000d1", email: "greet@example.com"},
      authenticated?: true,
      cached_roles: ["User"],
      cached_permissions: MapSet.new([])
    }

    %Socket{
      assigns: %{__changed__: %{}, phoenix_kit_current_scope: scope},
      private: %{connect_params: %{}, lifecycle: %Lifecycle{}}
    }
  end

  test "the disconnected (first) mount does not draw a random greeting" do
    for _ <- 1..20 do
      {:ok, socket} = Dashboard.mount(%{}, %{}, disconnected_socket())
      assert socket.assigns.greeting_key == :welcome_back
    end
  end

  test "an unmatched greeting key still renders (falls back to the default text)" do
    assigns = %{greeting: :some_future_key_this_build_does_not_know}

    html =
      ~H"""
      <Dashboard.welcome_block scope={nil} greeting={@greeting} />
      """
      |> rendered_to_string()

    assert html =~ "Welcome back"
  end
end
