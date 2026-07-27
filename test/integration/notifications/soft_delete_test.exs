defmodule PhoenixKit.Integration.Notifications.SoftDeleteTest do
  @moduledoc """
  The dismiss / restore soft-delete pattern and the `:dismissed` list filter:
  `:exclude` (active-only, the default), `:only` (the "Dismissed"/trash view),
  and the legacy `:include_dismissed` bool.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity
  alias PhoenixKit.Notifications
  alias PhoenixKit.Users.Auth

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "notif_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  # Create a notification for `target` (from a different actor, so the activity
  # hook fans it out) and return the created row.
  defp notify(target, actor) do
    Activity.log(%{
      action: "demo.notification",
      module: "demo",
      mode: "manual",
      actor_uuid: actor.uuid,
      resource_type: "demo",
      target_uuid: target.uuid,
      metadata: %{"notification_text" => "hello"}
    })

    {[n | _], _} = Notifications.list_for_user(target.uuid)
    n
  end

  defp uuids(target, opts) do
    {rows, _} = Notifications.list_for_user(target.uuid, opts)
    MapSet.new(rows, & &1.uuid)
  end

  describe "dismiss / restore + :dismissed filter" do
    setup do
      target = create_user()
      actor = create_user()
      %{target: target, actor: actor, n: notify(target, actor)}
    end

    test "a fresh notification is active, not in the dismissed list", %{target: t, n: n} do
      assert MapSet.member?(uuids(t, dismissed: :exclude), n.uuid)
      refute MapSet.member?(uuids(t, dismissed: :only), n.uuid)
    end

    test "dismiss moves it out of active and into the :only list", %{target: t, n: n} do
      assert {:ok, _} = Notifications.dismiss(t.uuid, n.uuid)
      refute MapSet.member?(uuids(t, dismissed: :exclude), n.uuid)
      assert MapSet.member?(uuids(t, dismissed: :only), n.uuid)
    end

    test "restore brings a dismissed notification back to active", %{target: t, n: n} do
      {:ok, _} = Notifications.dismiss(t.uuid, n.uuid)
      assert {:ok, %{dismissed_at: nil}} = Notifications.restore(t.uuid, n.uuid)
      assert MapSet.member?(uuids(t, dismissed: :exclude), n.uuid)
      refute MapSet.member?(uuids(t, dismissed: :only), n.uuid)
    end

    test "restore is idempotent on an already-active notification", %{target: t, n: n} do
      assert {:ok, %{dismissed_at: nil}} = Notifications.restore(t.uuid, n.uuid)
    end

    test "dismissing an unread notification also marks it read", %{target: t, n: n} do
      assert is_nil(n.seen_at)
      assert {:ok, %{seen_at: seen}} = Notifications.dismiss(t.uuid, n.uuid)
      refute is_nil(seen)
      assert Notifications.count_unread(t.uuid) == 0
    end

    test "restoring a dismissed notification keeps it read (not resurrected as unread)", %{
      target: t,
      n: n
    } do
      {:ok, _} = Notifications.dismiss(t.uuid, n.uuid)
      assert {:ok, %{dismissed_at: nil, seen_at: seen}} = Notifications.restore(t.uuid, n.uuid)
      refute is_nil(seen)
    end

    test "legacy include_dismissed: true still returns dismissed rows", %{target: t, n: n} do
      {:ok, _} = Notifications.dismiss(t.uuid, n.uuid)
      assert MapSet.member?(uuids(t, include_dismissed: true), n.uuid)
    end
  end
end
