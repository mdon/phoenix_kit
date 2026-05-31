defmodule PhoenixKit.Integration.Users.MultiSessionTest do
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "ms_#{System.unique_integer([:positive])}@example.com"

  defp owner_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, "Owner")
    Repo.get!(Auth.User, user.uuid)
  end

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  # Build a conn whose root (active) account is `user`, logged in like log_in_user.
  defp conn_for(user) do
    token = Auth.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  describe "add_account/3" do
    test "appends a real account and makes it active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      session = Plug.Conn.get_session(conn)
      assert length(session["pk_session_accounts"]) == 2
      # active token now resolves to the added user
      assert Auth.get_user_by_session_token(session["user_token"]).uuid == other.uuid
      # root unchanged
      [root_token | _] = session["pk_session_accounts"]
      assert Auth.get_user_by_session_token(root_token).uuid == owner.uuid
    end

    test "rejects invalid credentials, stack unchanged" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:error, :invalid_credentials} =
               MultiSession.add_account(conn, other.email, "wrong-password")

      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "rejects when the stack is full" do
      owner = owner_user()
      conn = conn_for(owner)

      conn =
        Enum.reduce(1..(MultiSession.max_accounts() - 1), conn, fn _, acc ->
          u = plain_user()
          {:ok, acc} = MultiSession.add_account(acc, u.email, "ValidPassword123!")
          acc
        end)

      full = plain_user()

      assert {:error, :stack_full} =
               MultiSession.add_account(conn, full.email, "ValidPassword123!")
    end
  end

  describe "switch_to/2" do
    test "activates a token already in the stack by ref" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:ok, conn, user} = MultiSession.switch_to(conn, root.ref)
      assert user.uuid == owner.uuid

      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid ==
               owner.uuid
    end

    test "rejects a ref not in the stack" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:error, :not_in_stack} = MultiSession.switch_to(conn, Ecto.UUID.generate())
    end
  end

  describe "remove_account/2" do
    test "deletes a non-root token from DB and stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      accounts = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      added = Enum.find(accounts, &(not &1.root?))
      added_token = Enum.at(Plug.Conn.get_session(conn)["pk_session_accounts"], 1)

      assert {:ok, conn} = MultiSession.remove_account(conn, added.ref)
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
      assert is_nil(Auth.get_user_by_session_token(added_token))
      # active fell back to root
      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid ==
               owner.uuid
    end

    test "refuses to remove the root account" do
      owner = owner_user()
      conn = conn_for(owner)
      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:error, :cannot_remove_root} = MultiSession.remove_account(conn, root.ref)
    end
  end

  describe "log_out_active/1 and delete_all_stack_tokens/1" do
    test "log_out_active switches to root when a non-root account is active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      added_token = Plug.Conn.get_session(conn)["user_token"]

      assert {:switched, conn, user} = MultiSession.log_out_active(conn)
      assert user.uuid == owner.uuid
      assert is_nil(Auth.get_user_by_session_token(added_token))
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "log_out_active returns :full when the root account is active" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:full, _conn} = MultiSession.log_out_active(conn)
    end

    test "delete_all_stack_tokens deletes every token in the stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      tokens = Plug.Conn.get_session(conn)["pk_session_accounts"]

      _conn = MultiSession.delete_all_stack_tokens(conn)
      assert Enum.all?(tokens, &is_nil(Auth.get_user_by_session_token(&1)))
    end
  end
end
