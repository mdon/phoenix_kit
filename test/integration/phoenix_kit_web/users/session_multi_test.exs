defmodule PhoenixKitWeb.Users.SessionMultiTest do
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "smc_#{System.unique_integer([:positive])}@example.com"

  defp make(role) do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role)
    Repo.get!(Auth.User, user.uuid)
  end

  defp login(conn, user) do
    token = Auth.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  describe "add_account gate" do
    test "owner can add an account", %{conn: conn} do
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
      assert length(get_session(conn)["pk_session_accounts"]) == 2
    end

    test "plain (non-admin) user can add an account when setting is on", %{conn: conn} do
      # Change 2: gate_allowed? no longer requires owner/admin — any authenticated user may
      # use the switcher when multi_session_enabled is on.
      Settings.update_boolean_setting("multi_session_enabled", true)
      user = make(nil)
      other = make(nil)
      conn = login(conn, user)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
      assert length(get_session(conn)["pk_session_accounts"]) == 2
    end

    test "forbidden when setting is off", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", false)
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"}
        })

      assert conn.status == 403 or redirected_to(conn) =~ "/"
      assert length(get_session(conn)["pk_session_accounts"]) == 1
    end
  end

  describe "switch / remove / logout" do
    setup %{conn: conn} do
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      %{conn: Phoenix.Controller.fetch_flash(conn), owner: owner, other: other}
    end

    test "set_active_account switches by ref", %{conn: conn, owner: owner} do
      [root | _] = MultiSession.list_accounts(get_session(conn))

      conn =
        put(conn, Routes.path("/users/session/active"), %{
          "ref" => root.ref,
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "logout active falls back to root", %{conn: conn, owner: owner} do
      conn = delete(conn, Routes.path("/users/log-out"))
      assert redirected_to(conn) == "/"
      assert get_session(conn)["user_token"]
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "logout all clears the session", %{conn: conn} do
      tokens = get_session(conn)["pk_session_accounts"]
      conn = delete(conn, Routes.path("/users/log-out") <> "?all=1")
      assert redirected_to(conn) == "/"
      refute get_session(conn)["user_token"]
      assert Enum.all?(tokens, &is_nil(Auth.get_user_by_session_token(&1)))
    end

    test "set_active_account works for a plain user when setting is on", %{conn: _conn} do
      # Change 2: gate_allowed? now allows any authenticated user when the setting is on.
      Settings.update_boolean_setting("multi_session_enabled", true)
      plain = make(nil)
      other = make(nil)
      conn = login(build_conn(), plain)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      conn = Phoenix.Controller.fetch_flash(conn)

      [_, second | _] = MultiSession.list_accounts(get_session(conn))

      conn =
        put(conn, Routes.path("/users/session/active"), %{
          "ref" => second.ref,
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
    end

    test "set_active_account is forbidden when multi_session setting is off", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", false)
      [root | _] = MultiSession.list_accounts(get_session(conn))

      conn =
        put(conn, Routes.path("/users/session/active"), %{
          "ref" => root.ref
        })

      assert conn.status == 403 or redirected_to(conn) =~ "/"
    end

    test "remove_account works for a plain user when setting is on", %{conn: _conn} do
      # Change 2: gate_allowed? now allows any authenticated user when the setting is on.
      Settings.update_boolean_setting("multi_session_enabled", true)
      plain = make(nil)
      other = make(nil)
      conn = login(build_conn(), plain)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      conn = Phoenix.Controller.fetch_flash(conn)

      [_, second | _] = MultiSession.list_accounts(get_session(conn))

      conn = delete(conn, Routes.path("/users/session/accounts/#{second.ref}"))
      assert redirected_to(conn) == Routes.path("/")
    end

    test "remove_account is forbidden when multi_session setting is off", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", false)
      [_, second | _] = MultiSession.list_accounts(get_session(conn))

      conn =
        delete(conn, Routes.path("/users/session/accounts/#{second.ref}"))

      assert conn.status == 403 or redirected_to(conn) =~ "/"
    end
  end

  describe "return_to open-redirect guard" do
    setup %{conn: conn} do
      owner = make("Owner")
      conn = login(conn, owner)
      other = make(nil)
      %{conn: Phoenix.Controller.fetch_flash(conn), owner: owner, other: other}
    end

    test "protocol-relative redirect is rejected (falls back to /)", %{conn: conn, other: other} do
      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "//evil.com"
        })

      assert redirected_to(conn) == Routes.path("/")
    end

    test "absolute URL redirect is rejected (falls back to /)", %{conn: conn, other: other} do
      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "https://evil.com/steal"
        })

      assert redirected_to(conn) == Routes.path("/")
    end

    test "a safe relative path is accepted", %{conn: conn, other: other} do
      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
    end
  end
end
