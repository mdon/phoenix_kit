defmodule PhoenixKit.Integration.Users.LiveSessionsPresenceTest do
  @moduledoc """
  Presence tracking now happens in `PhoenixKitWeb.Users.Auth`'s shared
  scope-mounting on_mount pipeline, not just the admin Live Sessions page
  itself — so ANY LiveView mounted through `:phoenix_kit_mount_current_scope`
  (or a `:phoenix_kit_ensure_*` hook), including a host app's own ordinary
  pages, shows up in "Live sessions" now. `PhoenixKitWeb.Test.PresenceProbeLive`
  (test/support/presence_probe_live.ex) stands in for such a page — deliberately
  NOT one of core's own admin LiveViews, since the point is that an ordinary
  page is tracked too.

  Presence is one named GenServer (a child of `PhoenixKit.Supervisor`, which a
  host app must add to its own tree — this repo's suite does not) that this
  suite does not start on its own; each test starts its own copy
  (`async: false`, mirrors `live_sessions_pagination_test.exs`).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Admin.{Events, Presence, SimplePresence}

  setup %{conn: conn} do
    start_supervised!(SimplePresence)
    {user, _token} = create_admin_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "a host LiveView mounted through :phoenix_kit_mount_current_scope is tracked in presence",
       %{conn: conn, user: user} do
    {:ok, _view, _html} = live(conn, "/__test/presence-probe/a")

    assert [%{user_uuid: uuid, current_page: "/__test/presence-probe/a"}] =
             Presence.list_active_sessions()

    assert uuid == user.uuid
  end

  test "navigating within the live_session updates current_page without adding a record",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/__test/presence-probe/a")
    assert [%{current_page: "/__test/presence-probe/a"}] = Presence.list_active_sessions()

    render_patch(view, "/__test/presence-probe/b")

    assert [session] = Presence.list_active_sessions()
    assert session.current_page == "/__test/presence-probe/b"
  end

  test "the record disappears once the LiveView process stops", %{conn: conn, user: user} do
    Events.subscribe_to_presence()

    {:ok, view, _html} = live(conn, "/__test/presence-probe/a")
    assert_receive {:user_session_connected, uuid, _info}, 500
    assert uuid == user.uuid
    assert [_session] = Presence.list_active_sessions()

    GenServer.stop(view.pid)

    assert_receive {:user_session_disconnected, ^uuid, _session_id}, 500
    assert Presence.list_active_sessions() == []
  end
end
