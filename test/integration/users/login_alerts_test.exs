defmodule PhoenixKit.Integration.Users.LoginAlertsTest do
  use PhoenixKitWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.LoginAlerts

  defp unique_email, do: "login_alert_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})

    user
  end

  defp conn_with_ua(ua) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {203, 0, 113, 42})
    |> Plug.Conn.put_req_header("user-agent", ua)
  end

  @chrome_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Chrome/120.0"
  @firefox_linux "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"

  describe "check/2 when new_login_alert_enabled is off (default)" do
    test "does not persist a known device" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)
      assert Repo.all(KnownDevice) == []
    end
  end

  describe "check/2 when new_login_alert_enabled is on" do
    setup do
      {:ok, _} = Settings.update_setting("new_login_alert_enabled", "true")
      :ok
    end

    test "a first-time login persists a new known device" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)

      assert [%KnownDevice{user_uuid: user_uuid, browser: "Chrome", os: "macOS"}] =
               Repo.all(KnownDevice)

      assert user_uuid == user.uuid
    end

    # Registration ends by logging the new user in through this exact path —
    # with no skip, every signup on an install with alerts on would receive a
    # "we noticed a new login" security email about the login it just
    # performed to finish registering.
    test "a first-time login does not send an alert email" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))

      refute_email_sent()
    end

    test "a genuinely new device (the account's second) does send an alert email" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert_email_sent(fn email -> assert email.subject =~ "New login" end)
    end

    test "a repeat login from the same device does not create a duplicate row" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)
      assert :ok = LoginAlerts.check(user, conn)

      assert [%KnownDevice{}] = Repo.all(KnownDevice)
    end

    test "a different browser from the same user is tracked as a separate device" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert [_, _] = Repo.all(KnownDevice)
    end

    test "devices are isolated per user" do
      user1 = create_user()
      user2 = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user1, conn)
      assert :ok = LoginAlerts.check(user2, conn)

      assert [_, _] = Repo.all(KnownDevice)
    end
  end
end
