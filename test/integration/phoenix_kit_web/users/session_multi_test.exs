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
    PhoenixKit.Test.Repo.get!(Auth.User, user.uuid)
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

    test "plain user is forbidden", %{conn: conn} do
      user = make(nil)
      other = make(nil)
      conn = login(conn, user)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"}
        })

      assert conn.status == 403 or redirected_to(conn) =~ "/"
      assert length(get_session(conn)["pk_session_accounts"]) == 1
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
  end
end
