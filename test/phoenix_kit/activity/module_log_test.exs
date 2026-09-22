defmodule PhoenixKit.Activity.ModuleLogTest do
  @moduledoc """
  `Activity.log/3` and `log_failed/3` — the call every module used to wrap
  in its own `Activity` helper. Entries are read back from the database.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Test.Fixtures

  setup do
    %{user: Fixtures.user_fixture()}
  end

  defp stored(%Entry{uuid: uuid}), do: Repo.get!(Entry, uuid)

  test "stores the module, the action and every option", %{user: user} do
    resource = UUIDv7.generate()

    assert {:ok, entry} =
             Activity.log("catalogue", "catalogue.item_updated",
               actor_uuid: user.uuid,
               mode: "auto",
               resource_type: "item",
               resource_uuid: resource,
               target_uuid: user.uuid,
               metadata: %{"name" => "Hinge"}
             )

    entry = stored(entry)
    assert entry.module == "catalogue"
    assert entry.action == "catalogue.item_updated"
    assert entry.mode == "auto"
    assert entry.actor_uuid == user.uuid
    assert entry.resource_type == "item"
    assert entry.resource_uuid == resource
    assert entry.target_uuid == user.uuid
    assert entry.metadata == %{"name" => "Hinge"}
    refute entry.permanent
  end

  test "mode defaults to manual, and metadata that is not a map is dropped" do
    {:ok, entry} = Activity.log("crm", "crm.list_created", metadata: "free text")
    entry = stored(entry)

    assert entry.mode == "manual"
    assert entry.metadata == %{}
    assert entry.actor_uuid == nil
  end

  test "metadata given as a keyword or pair list is stored as its map" do
    {:ok, keyword} = Activity.log("crm", "crm.noted", metadata: [note: "x"])
    {:ok, pairs} = Activity.log("crm", "crm.noted", metadata: [{"note", "y"}])

    assert stored(keyword).metadata == %{"note" => "x"}
    assert stored(pairs).metadata == %{"note" => "y"}
  end

  test "an entry is permanent only for permanent: true" do
    {:ok, kept} = Activity.log("crm", "crm.kept", permanent: true)
    {:ok, not_kept} = Activity.log("crm", "crm.not_kept", permanent: "true")

    assert stored(kept).permanent
    refute stored(not_kept).permanent
  end

  test "log_failed/3 marks the entry db_pending and keeps the caller's metadata" do
    {:ok, entry} =
      Activity.log_failed("projects", "projects.task_deleted", metadata: %{"count" => 3})

    assert stored(entry).metadata == %{"count" => 3, "db_pending" => true}

    {:ok, bare} = Activity.log_failed("projects", "projects.task_deleted")
    assert stored(bare).metadata == %{"db_pending" => true}
  end

  test "a failed attempt tells nobody: log_failed/3 fans out no notification", %{user: actor} do
    target = Fixtures.user_fixture()

    {:ok, _} =
      Activity.log_failed("projects", "projects.task_assigned",
        actor_uuid: actor.uuid,
        target_uuid: target.uuid,
        metadata: %{"notification_text" => "You were assigned a task"}
      )

    assert {[], _} = PhoenixKit.Notifications.list_for_user(target.uuid)

    {:ok, _} =
      Activity.log("projects", "projects.task_assigned",
        actor_uuid: actor.uuid,
        target_uuid: target.uuid,
        metadata: %{"notification_text" => "You were assigned a task"}
      )

    assert {[_], _} = PhoenixKit.Notifications.list_for_user(target.uuid)
  end

  test "an entry the changeset refuses is an error, not a raise" do
    assert {:error, %Ecto.Changeset{}} = Activity.log("crm", "")
    assert {:error, %Ecto.Changeset{}} = Activity.log("crm", String.duplicate("x", 101))
  end

  test "arguments it cannot use are an error, not a raise" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_arguments} = Activity.log("", "crm.x")
        assert {:error, :invalid_arguments} = Activity.log(nil, "crm.x")
        assert {:error, :invalid_arguments} = Activity.log("crm", "crm.x", %{metadata: %{}})
        assert {:error, :invalid_arguments} = Activity.log_failed("", "crm.x")
      end)

    assert log =~ "Activity not logged"
  end
end
