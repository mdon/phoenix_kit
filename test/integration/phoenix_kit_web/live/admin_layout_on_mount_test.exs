defmodule PhoenixKitWeb.Live.AdminLayoutOnMountTest do
  @moduledoc """
  `{PhoenixKitWeb.Users.Auth, :phoenix_kit_admin_layout}` puts a view that
  does its own gating into the admin layout — and does ONLY that.

  The probe view has no permission mapping and no gate of its own, so every
  case below also pins what the hook must not do: it never halts, redirects or
  403s (`:phoenix_kit_ensure_admin` would, for a view with no mapping).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth.User

  @path "/phoenix_kit/admin/__test/admin-layout-probe"

  defp confirmed_user(role \\ nil) do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "probe_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role)
    Repo.get!(User, user.uuid)
  end

  test "an admin gets the admin layout: sidebar and header around the view", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path)

    assert html =~ ~s(id="admin-layout-probe")
    assert html =~ ~s(id="pk-admin-sidebar")
    assert html =~ "<header"
    assert html =~ admin.email
  end

  test "an admin the view has no permission mapping for is not turned away", %{conn: conn} do
    {admin, _} = create_admin_user()

    # Admin, not Owner: the case `:phoenix_kit_ensure_admin` 403s for a view
    # outside the permission map.
    assert {:ok, _lv, html} = live(log_in_user(conn, admin), @path)
    assert html =~ "probe body"
  end

  test "a signed-in non-admin still mounts the view — the hook is not a gate", %{conn: conn} do
    user = confirmed_user()
    assert {:ok, _lv, html} = live(log_in_user(conn, user), @path)

    # The view renders, but bare: a visitor who cannot reach the admin area is
    # not shown the admin header or account menu on a page they merely opened.
    assert html =~ "probe body"
    refute html =~ ~s(id="pk-admin-sidebar")
    refute html =~ "<header"
    refute html =~ user.email
  end

  test "an anonymous visitor still mounts the view — the hook is not a gate", %{conn: conn} do
    assert {:ok, _lv, html} = live(conn, @path)

    assert html =~ "probe body"
    refute html =~ ~s(id="pk-admin-sidebar")
    refute html =~ "<header"
  end
end
