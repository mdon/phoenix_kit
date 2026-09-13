defmodule PhoenixKitWeb.Integration.Users.ActiveRoleSwitchTest do
  @moduledoc """
  Switching the active role over HTTP, the sign-in rule, and the safety rules
  that must hold while a user acts as a narrower role.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
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

  defp store_role(user, role) do
    {:ok, user} =
      Auth.merge_user_custom_fields(user, %{"active_role_uuid" => role.uuid},
        ensure_definitions: false
      )

    user
  end

  defp stored_role_uuid(user),
    do: Repo.get!(Auth.User, user.uuid).custom_fields["active_role_uuid"]

  defp switch_role(conn, params), do: put(conn, Routes.path("/users/session/role"), params)

  defp with_peer(conn) do
    n = System.unique_integer([:positive])
    ip = {127, 2, n |> div(256) |> rem(256), rem(n, 256)}
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  describe "PUT /users/session/role" do
    test "switches the role and narrows the scope", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => seller.uuid})

      assert redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ seller.name
      assert stored_role_uuid(user) == seller.uuid

      scope = Scope.for_user(Repo.get!(Auth.User, user.uuid))
      assert Scope.active_role(scope).uuid == seller.uuid
      refute Scope.has_role?(scope, "Admin")
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
      user = make_user(["Admin", seller.name]) |> store_role(seller)
      admin = Roles.get_role_by_name("Admin")
      return_to = Routes.path("/admin/settings/users")

      conn =
        conn
        |> log_in_user(user)
        |> switch_role(%{"role_uuid" => admin.uuid, "return_to" => return_to})

      assert redirected_to(conn) == return_to
      assert stored_role_uuid(user) == admin.uuid
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
      assert stored_role_uuid(user) == nil
    end

    test "refuses the always-on User role", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])
      user_role = Roles.get_role_by_name("User")

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => user_role.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert stored_role_uuid(user) == nil
    end

    test "refuses while the switcher is off", %{conn: conn, seller: seller} do
      Settings.update_boolean_setting("role_switcher_enabled", false)
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{"role_uuid" => seller.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert stored_role_uuid(user) == nil
    end

    test "a request without a role is refused, not a crash", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      conn = conn |> log_in_user(user) |> switch_role(%{})

      assert redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "refuses while impersonating", %{conn: conn, seller: seller, buyer: buyer} do
      target = make_user([seller.name, buyer.name])
      conn = log_in_user(conn, target)
      token = get_session(conn, :user_token)

      conn =
        conn
        |> put_session(:pk_impersonated_tokens, [token])
        |> switch_role(%{"role_uuid" => seller.uuid})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "another user"
      assert stored_role_uuid(target) == nil
    end
  end

  describe "impersonation while narrowed" do
    setup do
      Settings.update_boolean_setting("multi_session_enabled", true)
      :ok
    end

    test "an impersonation marks the session", %{conn: conn} do
      admin = make_user(["Admin"])
      target = make_user([])

      conn =
        conn
        |> log_in_user(admin)
        |> post(Routes.path("/users/session/impersonate/#{target.uuid}"), %{})

      assert MultiSession.impersonating?(get_session(conn))
    end

    test "an Admin acting as a custom role cannot impersonate", %{conn: conn, seller: seller} do
      admin = make_user(["Admin", seller.name]) |> store_role(seller)
      target = make_user([])

      conn =
        conn
        |> log_in_user(admin)
        |> post(Routes.path("/users/session/impersonate/#{target.uuid}"), %{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute MultiSession.impersonating?(get_session(conn))
      refute MultiSession.may_impersonate?(get_session(conn))
    end
  end

  describe "signing in" do
    defp sign_in(conn, user) do
      conn
      |> with_peer()
      |> post(Routes.path("/users/log-in"), %{
        "user" => %{"email" => user.email, "password" => @password}
      })
    end

    test "staff_first: an Admin who last acted as Seller starts as Admin", %{
      conn: conn,
      seller: seller
    } do
      user = make_user(["Admin", seller.name]) |> store_role(seller)

      conn = sign_in(conn, user)

      assert redirected_to(conn)
      assert stored_role_uuid(user) == Roles.get_role_by_name("Admin").uuid
    end

    test "staff_first: a non-staff user continues as their last role", %{
      conn: conn,
      seller: seller,
      buyer: buyer
    } do
      user = make_user([seller.name, buyer.name]) |> store_role(seller)

      sign_in(conn, user)

      assert stored_role_uuid(user) == seller.uuid
    end

    test "last_used: an Admin continues as their last role", %{conn: conn, seller: seller} do
      Settings.update_setting("role_switcher_sign_in_role", "last_used")
      user = make_user(["Admin", seller.name]) |> store_role(seller)

      sign_in(conn, user)

      assert stored_role_uuid(user) == seller.uuid
    end
  end

  describe "an open LiveView" do
    test "leaves an admin page when the user switches elsewhere", %{conn: conn, seller: seller} do
      user = make_user(["Admin", seller.name])

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(Routes.path("/admin/settings/users"))

      assert {:ok, _user, _role} = ActiveRole.switch(user, seller.uuid)

      {_path, flash} = assert_redirect(lv)
      assert flash["error"] =~ "role you switched to"
    end
  end
end
