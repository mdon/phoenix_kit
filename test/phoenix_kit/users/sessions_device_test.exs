defmodule PhoenixKit.Users.SessionsDeviceTest do
  @moduledoc """
  Integration tests for the self-service Active Sessions surface:
  device-enriched listing, the current-session flag, and the user-scoped
  revoke functions (which must never let one user revoke another's session).
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.SessionFingerprint

  defp user_fixture(email) do
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    user
  end

  defp session_token(user, ip, ua_hash) do
    fp = %SessionFingerprint{ip_address: ip, user_agent_hash: ua_hash}
    Auth.generate_user_session_token(user, fingerprint: fp)
  end

  defp known_device(user, ip, ua_hash, extra) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %KnownDevice{}
    |> KnownDevice.changeset(
      Map.merge(
        %{
          user_uuid: user.uuid,
          ip_address: ip,
          user_agent_hash: ua_hash,
          first_seen_at: now,
          last_seen_at: now
        },
        extra
      )
    )
    |> Repo.insert!()
  end

  describe "list_user_device_sessions/2" do
    test "enriches from known devices and flags the current session" do
      user = user_fixture("qr-sessions-list@example.com")
      ua = String.duplicate("a", 64)
      current = session_token(user, "203.0.113.1", ua)
      _other = session_token(user, "203.0.113.2", String.duplicate("b", 64))

      known_device(user, "203.0.113.1", ua, %{
        browser: "Chrome",
        os: "macOS",
        location: "Berlin, DE"
      })

      sessions = Sessions.list_user_device_sessions(user, current)
      assert length(sessions) == 2

      cur = Enum.find(sessions, & &1.is_current)
      assert cur.browser == "Chrome"
      assert cur.os == "macOS"
      assert cur.location == "Berlin, DE"
      assert cur.ip_address == "203.0.113.1"

      # A session with no matching known-device row degrades gracefully.
      other = Enum.find(sessions, &(not &1.is_current))
      assert other.browser == nil
      assert other.location == nil
    end

    test "no session is current when the token is unknown" do
      user = user_fixture("qr-sessions-nocurrent@example.com")
      _t = session_token(user, "203.0.113.3", String.duplicate("c", 64))

      sessions = Sessions.list_user_device_sessions(user, "not-a-real-token")
      assert Enum.all?(sessions, &(not &1.is_current))
    end
  end

  describe "revoke_user_session/2" do
    test "revokes the owner's session but not another user's" do
      user = user_fixture("qr-sessions-owner@example.com")
      intruder = user_fixture("qr-sessions-intruder@example.com")
      token = session_token(user, "203.0.113.5", String.duplicate("d", 64))

      [%{token_uuid: uuid}] = Sessions.list_user_device_sessions(user, token)

      # Cross-user revoke is refused even with the correct token uuid.
      assert {:error, :not_found} = Sessions.revoke_user_session(intruder, uuid)
      assert length(Sessions.list_user_device_sessions(user, token)) == 1

      # The owner can revoke it.
      assert :ok = Sessions.revoke_user_session(user, uuid)
      assert Sessions.list_user_device_sessions(user, token) == []
    end
  end

  describe "revoke_other_user_sessions/2" do
    test "keeps the current session and revokes the rest" do
      user = user_fixture("qr-sessions-others@example.com")
      current = session_token(user, "203.0.113.7", String.duplicate("e", 64))
      _s2 = session_token(user, "203.0.113.8", String.duplicate("f", 64))
      _s3 = session_token(user, "203.0.113.9", String.duplicate("0", 64))

      assert length(Sessions.list_user_device_sessions(user, current)) == 3

      assert Sessions.revoke_other_user_sessions(user, current) == 2

      remaining = Sessions.list_user_device_sessions(user, current)
      assert [%{is_current: true}] = remaining
    end

    test "with a nil token revokes every session" do
      user = user_fixture("qr-sessions-nil@example.com")
      _s1 = session_token(user, "203.0.113.10", String.duplicate("a", 64))
      _s2 = session_token(user, "203.0.113.11", String.duplicate("b", 64))

      assert Sessions.revoke_other_user_sessions(user, nil) == 2
      assert Sessions.list_user_device_sessions(user, nil) == []
    end
  end
end
