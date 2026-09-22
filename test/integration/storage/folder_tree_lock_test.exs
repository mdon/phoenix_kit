defmodule PhoenixKit.Integration.Storage.FolderTreeLockTest do
  @moduledoc """
  A folder move holds the folder-tree lock through its cycle check, so two
  moves at once in opposite directions cannot both pass and commit a loop.
  The sandbox runs every test on one connection and cannot race, so this
  holds the lock from a second, real connection and watches a move wait
  for it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage

  @lock "SELECT pg_advisory_lock(hashtext('phoenix_kit_storage:folder_tree'))"
  @unlock "SELECT pg_advisory_unlock(hashtext('phoenix_kit_storage:folder_tree'))"

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  test "a move waits for the folder-tree lock; a rename does not" do
    n = System.unique_integer([:positive])
    {:ok, a} = Storage.create_folder(%{name: "lock_a_#{n}"})
    {:ok, b} = Storage.create_folder(%{name: "lock_b_#{n}"})

    conn = holder()
    Postgrex.query!(conn, @lock, [])

    assert {:ok, renamed} = Storage.update_folder(a, %{name: "lock_a2_#{n}"})

    move = Task.async(fn -> Storage.update_folder(renamed, %{parent_uuid: b.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, @unlock, [])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end
end
