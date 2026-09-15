defmodule PhoenixKit.Users.UpdateUserAvatarParentFolderTest do
  @moduledoc """
  `Auth.update_user_avatar/4` places the stored avatar under the host's
  `PhoenixKit.UploadsParentFolder` hook, the same way the embedded avatar
  picker already does via `MediaSelectorModal`'s `scope_folder_id`. Media
  hierarchy phase 2, plan 8, task 2.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth

  defmodule Hook do
    @moduledoc false
    def parent_for(:avatar, _actor_uuid, _subject) do
      {:ok, Process.get(:update_user_avatar_test_folder_uuid)}
    end
  end

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "pk_avatar_parent_folder_#{System.unique_integer([:positive])}"
      )

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "avatar-parent-folder-test-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    # `store_file_in_buckets/6` queues `ProcessFileJob` via `Oban.insert/3` —
    # no Oban instance runs under `mix test` otherwise. `:manual` testing
    # just inserts the job row without executing the worker.
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      File.rm_rf(tmp_root)
      Application.delete_env(:phoenix_kit, :uploads_parent_folder)
    end)

    %{bucket: bucket}
  end

  defp create_user! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "update-avatar-parent-folder-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp write_tmp_source!(n) do
    path = Path.join(System.tmp_dir!(), "pk_avatar_source_#{n}.png")
    File.write!(path, "fake png bytes #{n}")
    path
  end

  test "hook configured: the stored file's folder_uuid is the hook's folder" do
    user = create_user!()

    {:ok, folder} =
      Storage.create_folder(%{name: "User avatars #{System.unique_integer([:positive])}"})

    Process.put(:update_user_avatar_test_folder_uuid, folder.uuid)

    Application.put_env(:phoenix_kit, :uploads_parent_folder, {Hook, :parent_for})

    source_path = write_tmp_source!(System.unique_integer([:positive]))

    assert {:ok, updated} = Auth.update_user_avatar(user, source_path, "avatar.png")

    file_uuid = updated.custom_fields["avatar_file_uuid"]
    assert is_binary(file_uuid)

    stored = Storage.get_file(file_uuid)
    assert stored.folder_uuid == folder.uuid
  end

  test "hook answering a stale folder uuid: the avatar still saves, at the root" do
    user = create_user!()
    Process.put(:update_user_avatar_test_folder_uuid, Ecto.UUID.generate())
    Application.put_env(:phoenix_kit, :uploads_parent_folder, {Hook, :parent_for})

    source_path = write_tmp_source!(System.unique_integer([:positive]))

    assert {:ok, updated} = Auth.update_user_avatar(user, source_path, "avatar.png")

    stored = Storage.get_file(updated.custom_fields["avatar_file_uuid"])
    assert stored.folder_uuid == nil
  end

  test "no hook configured: the stored file stays at the root" do
    user = create_user!()
    source_path = write_tmp_source!(System.unique_integer([:positive]))

    assert {:ok, updated} = Auth.update_user_avatar(user, source_path, "avatar.png")

    file_uuid = updated.custom_fields["avatar_file_uuid"]
    stored = Storage.get_file(file_uuid)
    assert stored.folder_uuid == nil
  end
end
