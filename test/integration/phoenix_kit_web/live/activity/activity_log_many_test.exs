defmodule PhoenixKitWeb.Live.Activity.LogManyTest do
  @moduledoc """
  The admin Activity page and `Activity.log_many/2`: one batch refreshes the
  page once with the message it already knows, and a message it does not know
  no longer takes the page down (it had a single `handle_info/2` clause).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Utils.Routes

  defp open_activity(conn) do
    {user, _token} = create_admin_user()
    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/activity"))
    view
  end

  test "a batch shows up on the open page", %{conn: conn} do
    view = open_activity(conn)
    refute render(view) =~ "widget.batch_marker_one"

    {:ok, _entries} =
      Activity.log_many([
        %{action: "widget.batch_marker_one", module: "widgets"},
        %{action: "widget.batch_marker_two", module: "widgets"}
      ])

    html = render(view)
    assert html =~ "widget.batch_marker_one"
    assert html =~ "widget.batch_marker_two"
  end

  test "a message it does not know does not crash the page", %{conn: conn} do
    view = open_activity(conn)

    send(view.pid, {:something_unexpected, %{any: "payload"}})
    send(view.pid, :a_bare_atom)

    assert render(view) =~ "Activity"
    assert Process.alive?(view.pid)
  end
end
