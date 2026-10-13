defmodule PhoenixKitWeb.Live.AdminEditPassthroughTest do
  @moduledoc """
  A LiveView rendered through the admin layout declares its Edit target with
  `assign_admin_edit/3`; the layout must show it as the first entry of the
  account menu — for an admin who holds the named module permission, and for
  nobody else.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth.User

  @path "/phoenix_kit/admin/__test/admin-edit-probe"

  # The account menu's links, in document order (the header's dropdown).
  defp menu_hrefs(html) do
    [menu] = Regex.run(~r/<ul[^>]*id="pk-admin-account-menu".*?<\/ul>/s, html)
    Regex.scan(~r/<a [^>]*href="([^"]+)"/, menu) |> Enum.map(&List.last/1)
  end

  defp plain_user do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "plain_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    Repo.get!(User, user.uuid)
  end

  test "an admin holding the permission gets Edit first in the account menu", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path <> "?perm=dashboard")

    assert html =~ "probe body"
    assert html =~ ~s(id="pk-admin-sidebar")
    assert [first, second | _] = menu_hrefs(html)
    assert first == "/admin/probe/1/edit"
    assert second =~ "settings"
    assert html =~ "Edit probe"
  end

  test "no permission argument: any admin gets it", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path)

    assert hd(menu_hrefs(html)) == "/admin/probe/1/edit"
  end

  test "an admin without the named permission gets no Edit", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path <> "?perm=no_such_module_key")

    assert html =~ "probe body"
    refute html =~ "/admin/probe/1/edit"
    refute html =~ "Edit probe"
  end

  test "a signed-in non-admin gets no Edit", %{conn: conn} do
    # The probe view only mounts the scope (no admin gate of its own), so a
    # non-admin is served the page; what must hold is that no Edit target
    # reaches the render. `assign_admin_edit/3` assigns nothing for them, and
    # the menu entry has its own admin-area backstop.
    assert {:ok, _lv, html} = live(log_in_user(conn, plain_user()), @path)

    assert html =~ "probe body"
    refute html =~ "/admin/probe/1/edit"
    refute html =~ "Edit probe"
  end
end
