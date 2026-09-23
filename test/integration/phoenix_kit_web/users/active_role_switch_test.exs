defmodule PhoenixKitWeb.Integration.Users.ActiveRoleSwitchTest do
  @moduledoc """
  Switching the active role over HTTP, the per-session storage, and the safety
  rules that must hold while a session acts as a narrower role.
  """
  use PhoenixKitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.MultiSession

  @password "ValidPassword123!"

  defp unique_email, do: "ars_#{System.unique_integer([:positive])}@example.com"

  # The first user registered in a fresh sandbox becomes Owner; seed one so the
  # users below get the roles the test gives them.
  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)

    {:ok, seller} = Roles.create_role(%{name: "Seller#{System.unique_integer([:positive])}"})
    {:ok, buyer} = Roles.create_role(%{name: "Buyer#{System.unique_integer([:positive])}"})
    Settings.update_boolean_setting("role_switcher_enabled", true)

    %{seller: seller, buyer: buyer}
  end

  defp make_user(role_names) do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, user} = Auth.admin_confirm_user(user)
    for name <- role_names, do: {:ok, _} = Roles.assign_role(user, name)
    Repo.get!(Auth.User, user.uuid)
  end

  # What the controller does, without the round-trip: the role stored on THIS
  # conn's session token.
  defp act_as(conn, role) do
    token = get_session(conn, :user_token)
    Repo.update_all(token_query(token), set: [active_role_uuid: role.uuid])
    conn
  end

  defp token_query(token),
    do: from(t in UserToken, where: t.token == ^token and t.context == "session")

  defp stored_role_uuid(conn) do
    conn |> get_session(:user_token) |> token_query() |> Repo.one!() |> Map.get(:active_role_uuid)
  end

  # The scope the plug / on_mount hooks would build for this conn's session.
  defp session_scope(conn) do
    conn |> get_session(:user_token) |> Auth.get_user_by_session_token() |> Scope.for_user()
  end

  defp switch_role(conn, params), do: put(conn, Routes.path("/users/session/role"), params)

  describe "PUT /users/session/role" do
    test "switches the role and narrows the scope", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => seller.uuid})

      assert redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ seller.name
      assert stored_role_uuid(conn) == seller.uuid

      scope = session_scope(conn)
      assert Scope.active_role(scope).uuid == seller.uuid
      refute Scope.has_role?(scope, "Admin")
    end

    test "only this session changes: another session of the same user is untouched", %{
      conn: conn,
      seller: seller
    } do
      user = make_user(["Admin", seller.name])
      other = log_in_user(build_conn(), user)

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => seller.uuid})

      assert stored_role_uuid(conn) == seller.uuid
      assert stored_role_uuid(other) == nil
      assert Scope.has_role?(session_scope(other), "Admin")
    end

    test "a return_to the new role cannot reach is replaced", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      return_to = Routes.path("/admin/settings/users")

      conn =
        conn
        |> log_in_user(user)
        |> switch_role(%{"role_uuid" => seller.uuid, "return_to" => return_to})

      refute redirected_to(conn) == return_to
    end

    test "a return_to the new role can reach is kept", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      admin = Roles.get_role_by_name("Admin")
      return_to = Routes.path("/admin/settings/users")

      conn =
        conn
        |> log_in_user(user)
        |> act_as(seller)
        |> switch_role(%{"role_uuid" => admin.uuid, "return_to" => return_to})

      assert redirected_to(conn) == return_to
      assert stored_role_uuid(conn) == admin.uuid
    end

    test "a custom role with an admin permission is judged page by page", %{
      conn: conn,
      seller: seller
    } do
      {:ok, _} = Permissions.grant_permission(seller.uuid, "media")
      user = make_user(["Admin", seller.name])

      # Seller may enter the admin area (it holds `media`), but not the users
      # settings page: that return_to is dropped, not bounced into the gate.
      conn =
        conn
        |> log_in_user(user)
        |> switch_role(%{
          "role_uuid" => seller.uuid,
          "return_to" => Routes.path("/admin/settings/users")
        })

      refute redirected_to(conn) == Routes.path("/admin/settings/users")

      # A page Seller CAN mount is kept.
      conn =
        build_conn()
        |> log_in_user(user)
        |> switch_role(%{"role_uuid" => seller.uuid, "return_to" => Routes.path("/admin/media")})

      assert redirected_to(conn) == Routes.path("/admin/media")
    end

    test "an off-site return_to is never followed", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      conn =
        conn
        |> log_in_user(user)
        |> switch_role(%{"role_uuid" => seller.uuid, "return_to" => "//evil.example"})

      refute redirected_to(conn) =~ "evil.example"
    end

    test "refuses a role the user does not hold", %{conn: conn, seller: seller, buyer: buyer} do
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => buyer.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert stored_role_uuid(conn) == nil
    end

    test "refuses the always-on User role", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      user_role = Roles.get_role_by_name("User")

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => user_role.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert stored_role_uuid(conn) == nil
    end

    test "refuses while the switcher is off", %{conn: conn, seller: seller} do
      Settings.update_boolean_setting("role_switcher_enabled", false)
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => seller.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert stored_role_uuid(conn) == nil
    end

    test "a request without a role is refused, not a crash", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{})

      assert redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "a new session" do
    test "starts in the default role even when another session switched", %{
      conn: conn,
      seller: seller
    } do
      user = make_user(["Admin", seller.name])
      _switched = conn |> log_in_user(user) |> act_as(seller)

      fresh = log_in_user(build_conn(), user)

      assert stored_role_uuid(fresh) == nil
      assert Scope.active_role(session_scope(fresh)).name == "Admin"
    end

    test "the default is the first held role in role order", %{
      conn: conn,
      seller: seller,
      buyer: buyer
    } do
      user = make_user([seller.name, buyer.name])
      :ok = Roles.reorder_roles([buyer.uuid, seller.uuid])

      conn = log_in_user(conn, user)

      assert Scope.active_role(session_scope(conn)).uuid == buyer.uuid
    end
  end

  describe "impersonation" do
    setup do
      Settings.update_boolean_setting("multi_session_enabled", true)
      :ok
    end

    test "an impersonation session has a role of its own and may switch it", %{
      conn: conn,
      seller: seller,
      buyer: buyer
    } do
      admin = make_user(["Admin"])
      target = make_user([seller.name, buyer.name])
      targets_own = build_conn() |> log_in_user(target) |> act_as(buyer)

      conn =
        conn
        |> log_in_user(admin)
        |> post(Routes.path("/users/session/impersonate/#{target.uuid}"), %{})

      # The borrowed session starts at the target's default, not their choice.
      assert Scope.active_role(session_scope(conn)).uuid == seller.uuid
      assert Scope.switchable_roles(session_scope(conn)) != []

      conn = switch_role(conn, %{"role_uuid" => buyer.uuid})
      assert stored_role_uuid(conn) == buyer.uuid

      # ...and the target's own session was never touched.
      assert stored_role_uuid(targets_own) == buyer.uuid
      assert [%{role: _}, %{active?: true}] = MultiSession.list_accounts(get_session(conn))
    end

    test "an Admin acting as a custom role cannot impersonate", %{conn: conn, seller: seller} do
      admin = make_user(["Admin", seller.name])
      target = make_user([])

      conn =
        conn
        |> log_in_user(admin)
        |> act_as(seller)
        |> post(Routes.path("/users/session/impersonate/#{target.uuid}"), %{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute MultiSession.may_impersonate?(get_session(conn))
    end
  end

  describe "an open LiveView" do
    test "leaves an admin page when its session switches elsewhere", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      conn = log_in_user(conn, user)
      token = get_session(conn, :user_token)

      {:ok, lv, _html} = live(conn, Routes.path("/admin/settings/users"))

      session_user = Auth.get_user_by_session_token(token)
      assert {:ok, _role} = ActiveRole.switch(session_user, token, seller.uuid)

      # The redirect follows a broadcast; the default 100 ms is too short
      # on a busy machine.
      {_path, flash} = assert_redirect(lv, 2_000)
      assert flash["error"] =~ "role you switched to"
    end

    test "stays when another session of the same user switches", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      other = log_in_user(build_conn(), user)
      other_token = get_session(other, :user_token)

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(Routes.path("/admin/settings/users"))

      other_user = Auth.get_user_by_session_token(other_token)
      assert {:ok, _role} = ActiveRole.switch(other_user, other_token, seller.uuid)

      # The refresh ran (same user topic) but this session is still Admin.
      assert render(lv) =~ "role_switcher_enabled"
    end
  end
end
