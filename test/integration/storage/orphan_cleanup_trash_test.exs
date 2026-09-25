defmodule PhoenixKit.Modules.Storage.OrphanCleanupTrashTest do
  @moduledoc """
  Orphan cleanup ("Move all orphaned to trash", `mix
  phoenix_kit.cleanup_orphaned_files --delete`) moves files to the trash and
  never deletes them: an orphan is a guess, so it goes where a person can
  restore it until the trash prune runs.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Workers.DeleteOrphanedFileJob
  alias PhoenixKit.Users.Auth

  defp file! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "orphan-trash-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "o.png",
        file_name: "o.png",
        file_path: "x/o.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {user, file}
  end

  defp perform(uuid),
    do: DeleteOrphanedFileJob.perform(%Oban.Job{args: %{"file_uuid" => uuid}})

  test "an orphan is moved to the trash, not deleted, and can be restored" do
    {_user, file} = file!()
    assert Storage.file_orphaned?(file.uuid)

    assert :ok = perform(file.uuid)

    trashed = Storage.get_file(file.uuid)
    assert trashed.status == "trashed"
    assert trashed.trashed_at

    assert {:ok, restored} = Storage.restore_file(trashed.uuid)
    assert restored.status == "active"
  end

  test "a file that is referenced again by the time the job runs is left alone" do
    {user, file} = file!()
    {:ok, _} = Auth.merge_user_custom_fields(user, %{"avatar_file_uuid" => file.uuid}, [])

    refute Storage.file_orphaned?(file.uuid)
    assert :ok = perform(file.uuid)
    assert Storage.get_file(file.uuid).status == "active"
  end
end
