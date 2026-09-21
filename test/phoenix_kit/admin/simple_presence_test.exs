defmodule PhoenixKit.Admin.SimplePresenceTest do
  @moduledoc """
  Unit coverage for `PhoenixKit.Admin.SimplePresence`'s idempotent
  `(user_uuid, session_id)` keying and monitor ref-counting — the multi-tab
  bug this module's key change fixes: before it, a SECOND tab/mount tracking
  the same user overwrote the FIRST tab's monitor, so closing the second tab
  evicted the presence row even though the first tab was still open.

  A single named GenServer + named ETS table, not started by
  `test_helper.exs` (a host app supervises it in production) — every test
  starts its own copy, so `async: false` (mirrors
  `live_sessions_pagination_test.exs`).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Admin.{Events, Presence, SimplePresence}

  setup do
    start_supervised!(SimplePresence)
    :ok
  end

  defp user(uuid \\ nil), do: %{uuid: uuid || Ecto.UUID.generate(), email: "presence@test.local"}

  describe "track_user/2 idempotency" do
    test "tracking the same (user, session_id) twice from one process yields one record" do
      u = user()

      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})
      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})

      assert [%{user_uuid: uuid, session_id: "s1"}] = SimplePresence.list_active_sessions()
      assert uuid == u.uuid
    end

    test "the same user with two different session_ids yields two records" do
      u = user()

      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})
      assert :ok = SimplePresence.track_user(u, %{session_id: "s2", current_page: nil})

      session_ids =
        SimplePresence.list_active_sessions()
        |> Enum.filter(&(&1.user_uuid == u.uuid))
        |> Enum.map(& &1.session_id)
        |> Enum.sort()

      assert session_ids == ["s1", "s2"]
    end
  end

  describe "multi-tab regression: closing one tab must not evict a session another tab still holds" do
    test "the record survives the second tracker's exit and disappears only after the first's" do
      Events.subscribe_to_presence()
      u = user()
      session_id = "multitab-#{System.unique_integer([:positive])}"
      parent = self()

      # Two independent processes tracking the SAME (user, session) — the
      # shape of two open tabs sharing one login.
      pid_a =
        spawn(fn ->
          :ok = SimplePresence.track_user(u, %{session_id: session_id, current_page: nil})
          send(parent, :a_tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :a_tracked, 500

      pid_b =
        spawn(fn ->
          :ok = SimplePresence.track_user(u, %{session_id: session_id, current_page: nil})
          send(parent, :b_tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :b_tracked, 500

      assert [%{user_uuid: uuid, session_id: ^session_id}] = SimplePresence.list_active_sessions()
      assert uuid == u.uuid

      # Close tab B (the second tracker) — tab A is still open.
      send(pid_b, :stop)

      # Synchronize on the stats broadcast every :DOWN triggers, then check the
      # mailbox for a disconnect that must NOT be there (see module doc: a
      # disconnect broadcast — if it happened — is sent from the same
      # handle_info/2 call, strictly before the stats broadcast it is ordered
      # against here). Pinned to THIS test's uuid — presence events broadcast
      # on a suite-wide PubSub topic, so an unpinned pattern can false-fail on
      # a concurrently-running, unrelated test's own disconnect.
      assert_receive {:presence_stats_updated, _}, 500
      refute_receive {:user_session_disconnected, ^uuid, _}, 100

      assert [%{user_uuid: ^uuid, session_id: ^session_id}] =
               SimplePresence.list_active_sessions()

      # Now close tab A (the last one) — the record must go.
      send(pid_a, :stop)

      assert_receive {:user_session_disconnected, ^uuid, ^session_id}, 500
      assert SimplePresence.list_active_sessions() == []
    end
  end

  describe "connected broadcast fires once per session, stats broadcast fires every track" do
    test "a repeat track_user does not resend user_session_connected but does resend stats" do
      Events.subscribe_to_presence()
      u = user()

      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})
      assert_receive {:user_session_connected, uuid, _info}, 500
      assert uuid == u.uuid
      assert_receive {:presence_stats_updated, _}, 500

      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})
      # Pinned to THIS test's uuid — see the multi-tab regression test above
      # for why an unpinned pattern is unsafe on a suite-wide PubSub topic.
      refute_receive {:user_session_connected, ^uuid, _}, 200
      assert_receive {:presence_stats_updated, _}, 500
    end
  end

  describe "Presence.update_current_page/3" do
    test "updates :current_page on the existing record without creating a new one or connect event" do
      Events.subscribe_to_presence()
      u = user()

      assert :ok = SimplePresence.track_user(u, %{session_id: "s1", current_page: nil})
      assert_receive {:user_session_connected, uuid, _info}, 500
      assert uuid == u.uuid

      assert :ok = Presence.update_current_page(u.uuid, "s1", "/orders")
      refute_receive {:user_session_connected, ^uuid, _}, 200

      assert [%{user_uuid: ^uuid, session_id: "s1", current_page: "/orders"}] =
               SimplePresence.list_active_sessions()
    end

    test "is a no-op when the session is no longer tracked" do
      assert :ok = Presence.update_current_page(Ecto.UUID.generate(), "ghost", "/orders")
    end
  end

  describe "happy path" do
    test "a session disappears and broadcasts a disconnect when its process dies" do
      Events.subscribe_to_presence()
      u = user()
      session_id = "happy-#{System.unique_integer([:positive])}"
      parent = self()

      pid =
        spawn(fn ->
          :ok = SimplePresence.track_user(u, %{session_id: session_id, current_page: nil})
          send(parent, :tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :tracked, 500
      assert_receive {:user_session_connected, uuid, _info}, 500
      assert uuid == u.uuid

      send(pid, :stop)

      assert_receive {:user_session_disconnected, ^uuid, ^session_id}, 500
      assert SimplePresence.list_active_sessions() == []
    end
  end
end
