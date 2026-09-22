defmodule PhoenixKit.Integration.Storage.ReorganizerResourceSourceTest do
  # Hook config lives in application env, read by the planner.
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, ResourceFolders}
  alias PhoenixKit.Modules.Storage.Reorganizer.{Action, ResourceSource}
  alias PhoenixKit.Users.Auth

  @app :resource_source_test
  @prefix "rs-rec-"
  @pending "rs-pending-"

  # The subject tells nothing here; answers come from the process.
  defmodule Hook do
    @moduledoc false
    def parent(:rec, _actor, record) do
      Process.put(:parent_calls, [record.uuid | Process.get(:parent_calls, [])])

      case Map.get(Process.get(:answers, %{}), record.uuid, Process.get(:answer)) do
        :raise -> raise "secret-message"
        answer -> answer
      end
    end

    def name(record, _actor) do
      case Process.get(:names, %{}) |> Map.get(record.uuid) do
        :raise -> raise "secret-message"
        nil -> nil
        name -> {:ok, name}
      end
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)

    :ok
  end

  defp spec(opts \\ []) do
    %{
      source: "rs",
      app: @app,
      pending_prefix: @pending,
      kinds: [
        %{
          kind: :rec,
          schema: StorageFile,
          prefix: @prefix,
          label: :original_file_name,
          pointer: Keyword.get(opts, :pointer, {:data, "files_folder_uuid"}),
          live: &where(&1, [r], r.status != "trashed")
        }
      ]
    }
  end

  defp plan(opts \\ []),
    do: ResourceSource.plan(spec(opts), nil, Keyword.take(opts, [:pending_days]))

  defp hook(answer) do
    Process.put(:answer, answer)
    Application.put_env(@app, :attachments_parent_folder, {Hook, :parent})
  end

  defp names(map) do
    Process.put(:names, map)
    Application.put_env(@app, :attachments_folder_name, {Hook, :name})
  end

  defp record!(name, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %StorageFile{
          original_file_name: name,
          file_name: "rs-#{n}",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "rs-#{n}",
          user_file_checksum: "rs-u-#{n}",
          size: 1,
          status: "active",
          data: %{},
          user_uuid: user_uuid()
        },
        attrs
      )
    )
  end

  defp user_uuid do
    Process.get(:rs_user) ||
      (
        {:ok, user} =
          Auth.register_user(%{
            email: "rs-#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:rs_user, user.uuid)
        user.uuid
      )
  end

  defp folder!(name, parent \\ nil) do
    {:ok, folder} = Storage.create_folder(%{name: name, parent_uuid: parent && parent.uuid})
    folder
  end

  defp det(record), do: @prefix <> record.uuid

  defp point!(record, folder),
    do:
      ResourceFolders.write_pointer(
        StorageFile,
        record.uuid,
        {:data, "files_folder_uuid"},
        folder.uuid
      )

  defp of(actions, kind, label),
    do: Enum.filter(actions, &(&1.kind == kind and &1.label == label))

  test "every action is one the engine accepts" do
    target = folder!("Target")
    a = record!("A")
    folder!(det(a))
    folder!(@pending <> Ecto.UUID.generate())
    folder!(@prefix <> Ecto.UUID.generate())
    hook({:ok, target.uuid})

    actions = plan()
    assert actions != []
    Enum.each(actions, &Action.new!/1)
  end

  describe "without a hook" do
    test "only reports: orphans and pending folders, no move and no trash" do
      a = record!("A")
      folder!(det(a))
      orphan = folder!(@prefix <> Ecto.UUID.generate())
      pending = folder!(@pending <> Ecto.UUID.generate())
      old = DateTime.utc_now() |> DateTime.add(-30 * 86_400) |> DateTime.truncate(:second)
      Repo.update_all(from(f in Folder, where: f.uuid == ^pending.uuid), set: [inserted_at: old])

      actions = plan()
      refute Enum.any?(actions, &(&1.op in [:move, :trash]))
      assert [%{reason: "record missing, 0 file(s)"}] = of(actions, :orphan, orphan.name)
      assert [%{op: :report} = stale] = of(actions, :pending, pending.name)
      assert stale.reason =~ "not trashed"
      refute Process.get(:parent_calls)
    end

    test "a hook that is configured but not callable is one hook_error" do
      Application.put_env(@app, :attachments_parent_folder, {Hook, :missing})
      a = record!("A")
      folder!(det(a))

      assert [%{kind: :hook_error, reason: reason}] =
               Enum.filter(plan(), &(&1.kind == :hook_error))

      assert reason =~ "not callable"
    end
  end

  describe "moves" do
    test "a legacy root folder moves under the parent; the pointer is back-filled" do
      target = folder!("Target")
      a = record!("A")
      folder = folder!(det(a))
      hook({:ok, target.uuid})

      assert [move] = of(plan(), :rec, "A")
      assert %{op: :move, parent_uuid: parent, on_conflict: :suffix, counts: {0, 0}} = move
      assert parent == target.uuid
      assert move.folder.uuid == folder.uuid
      assert move.after_move.() == :ok
      assert Repo.get!(StorageFile, a.uuid).data["files_folder_uuid"] == folder.uuid
    end

    test "without a pointer a conflict is reported, and nothing is back-filled" do
      target = folder!("Target")
      a = record!("A")
      folder!(det(a))
      hook({:ok, target.uuid})

      assert [%{on_conflict: :report, after_move: nil}] = of(plan(pointer: nil), :rec, "A")
    end

    test "the back-fill leaves a record that is no longer live alone" do
      target = folder!("Target")
      a = record!("A")
      folder!(det(a))
      hook({:ok, target.uuid})
      [move] = of(plan(), :rec, "A")

      Repo.update_all(from(f in StorageFile, where: f.uuid == ^a.uuid), set: [status: "trashed"])
      assert move.after_move.() == {:error, :record_not_live}
    end

    test "a folder already in place with its pointer is no action" do
      target = folder!("Target")
      a = record!("A")
      folder = folder!(det(a), target)
      point!(a, folder)
      hook({:ok, target.uuid})

      assert of(plan(), :rec, "A") == []
    end

    test "a pointer-found folder keeps its own name unless it is still a module name" do
      target = folder!("Target")
      [a, b] = [record!("A"), record!("B")]
      renamed = folder!("Named by a person")
      pending = folder!(@pending <> Ecto.UUID.generate())
      point!(a, renamed)
      point!(b, pending)
      hook({:ok, target.uuid})
      names(%{a.uuid => "Host A", b.uuid => "Host B"})

      assert [%{name: nil}] = of(plan(), :rec, "A")
      assert [%{name: "Host B"}] = of(plan(), :rec, "B")
    end
  end

  describe "hook failures" do
    test "a raising parent hook skips the record into one hook_error, logged by shape" do
      a = record!("A")
      folder!(det(a))
      hook(:raise)

      log =
        capture_log(fn ->
          actions = plan()
          refute Enum.any?(actions, &(&1.op == :move))

          assert [%{label: "attachments parent hook", reason: reason}] =
                   of(actions, :hook_error, "attachments parent hook")

          assert reason =~ "1 record(s)"
        end)

      assert log =~ inspect(Hook)
      assert log =~ "RuntimeError"
      refute log =~ "secret-message"
    end

    test "a failing name hook is a hook_error too, never a silent fallback" do
      target = folder!("Target")
      a = record!("A")
      folder!(det(a))
      hook({:ok, target.uuid})
      names(%{a.uuid => :raise})

      capture_log(fn ->
        actions = plan()
        assert of(actions, :rec, "A") == []
        assert [_] = of(actions, :hook_error, "attachments folder-name hook")
      end)
    end

    test "no hook is called for a record with no folder" do
      _a = record!("A")
      hook({:ok, folder!("Target").uuid})
      plan()
      refute Process.get(:parent_calls)
    end
  end

  describe "a root answer" do
    test "never moves a folder that has a parent" do
      elsewhere = folder!("Elsewhere")
      a = record!("A")
      folder = folder!(det(a), elsewhere)
      hook(nil)

      actions = plan()
      assert [move] = of(actions, :rec, "A")
      assert {move.parent_uuid, move.name, move.folder.uuid} == {elsewhere.uuid, nil, folder.uuid}
      assert is_function(move.after_move, 0)
      assert [_] = Enum.filter(actions, &(&1.kind == :hook_nil))
    end

    test "with a copy at the root, that copy is the folder and one elsewhere is relocated" do
      elsewhere = folder!("Elsewhere")
      a = record!("A")
      root = folder!(det(a))
      stray = folder!(det(a), elsewhere)
      hook(nil)

      actions = plan()
      assert [%{folder: %{uuid: moved}}] = of(actions, :rec, "A")
      assert moved == root.uuid
      assert [%{folder: %{uuid: relocated}}] = of(actions, :relocated, "A")
      assert relocated == stray.uuid
      refute Enum.any?(actions, &(&1.kind in [:duplicate, :hook_nil]))
    end

    test "with no copy at the root and two elsewhere, one duplicate names both" do
      [e1, e2] = [folder!("E1"), folder!("E2")]
      a = record!("A")
      [c1, c2] = [folder!(det(a), e1), folder!(det(a), e2)]
      hook(nil)

      actions = plan()
      assert [dup] = of(actions, :duplicate, "A")
      assert dup.reason =~ c1.uuid and dup.reason =~ c2.uuid
      assert of(actions, :relocated, "A") == []
    end
  end

  describe "where a record's folder is looked for" do
    test "copies under the parent and at the root are one duplicate; any other copy is relocated" do
      [target, elsewhere] = [folder!("Target"), folder!("Elsewhere")]
      a = record!("A")
      under = folder!(det(a), target)
      root = folder!(det(a))
      third = folder!(det(a), elsewhere)
      hook({:ok, target.uuid})

      actions = plan()
      assert [dup] = of(actions, :duplicate, "A")
      assert dup.reason =~ under.uuid and dup.reason =~ root.uuid
      assert [%{folder: %{uuid: relocated}, reason: reason}] = of(actions, :relocated, "A")
      assert relocated == third.uuid
      assert reason =~ "Elsewhere"
      assert reason =~ "acting user"
    end

    test "a host-named folder is the folder, and the root copy the planner also looks at makes it a duplicate" do
      target = folder!("Target")
      a = record!("A")
      host = folder!("Host A", target)
      under = folder!(det(a), target)
      hook({:ok, target.uuid})
      names(%{a.uuid => "Host A"})

      assert [dup] = of(plan(), :duplicate, "A")
      assert dup.reason =~ host.uuid and dup.reason =~ under.uuid
    end

    test "a host-named folder another record points at is not adopted; the deterministic name is wanted" do
      target = folder!("Target")
      [a, b] = [record!("A"), record!("B")]
      shared = folder!("Shared", target)
      point!(b, shared)
      folder!(det(a))
      hook({:ok, target.uuid})
      names(%{a.uuid => "Shared", b.uuid => "Shared"})

      assert [move] = of(plan(), :rec, "A")
      assert move.name == det(a)
    end

    test "the host name is looked for at the root too when the parent is the root" do
      a = record!("A")
      host = folder!("Host A")
      folder!(det(a), folder!("Elsewhere"))
      hook(nil)
      names(%{a.uuid => "Host A"})

      actions = plan()
      assert [%{folder: %{uuid: current}}] = of(actions, :rec, "A")
      assert current == host.uuid
      assert [_] = of(actions, :relocated, "A")
    end
  end

  describe "records meeting" do
    test "two records on one folder are one duplicate, neither moves" do
      target = folder!("Target")
      [a, b] = [record!("A"), record!("B")]
      folder = folder!("Common")
      point!(a, folder)
      point!(b, folder)
      hook({:ok, target.uuid})

      actions = plan()
      assert [dup] = Enum.filter(actions, &(&1.kind == :duplicate))
      assert dup.label == "Common"
      refute Enum.any?(actions, &(&1.op == :move))
    end

    test "two moves onto one target are one duplicate, neither moves" do
      target = folder!("Target")
      [a, b] = [record!("A"), record!("B")]
      folder!(det(a))
      folder!(det(b))
      hook({:ok, target.uuid})
      names(%{a.uuid => "Same", b.uuid => "Same"})

      actions = plan()
      assert [dup] = Enum.filter(actions, &(&1.kind == :duplicate))
      assert dup.reason =~ "(parent #{target.uuid}, name Same)"
      refute Enum.any?(actions, &(&1.op == :move))
    end
  end

  describe "orphans and pending folders" do
    test "a record that is not live leaves an orphan; a claimed folder never is one" do
      target = folder!("Target")
      gone = record!("Gone", %{status: "trashed"})
      orphan = folder!(det(gone), target)
      live = record!("Live")
      folder!(det(live))
      claimed = folder!(@prefix <> Ecto.UUID.generate())
      point!(live, claimed)
      hook({:ok, target.uuid})

      actions = plan()
      assert [%{reason: "record status trashed, 0 file(s)"}] = of(actions, :orphan, orphan.name)
      assert of(actions, :orphan, claimed.name) == []
    end

    test "an orphan under a parent no hook named is out of scope" do
      gone_parent = folder!("Somewhere")
      orphan = folder!(@prefix <> Ecto.UUID.generate(), gone_parent)
      hook({:ok, folder!("Target").uuid})

      assert of(plan(), :orphan, orphan.name) == []
    end

    test "a stale empty pending folder is trashed; one with files is reported by name" do
      hook({:ok, folder!("Target").uuid})
      old = DateTime.utc_now() |> DateTime.add(-30 * 86_400) |> DateTime.truncate(:second)
      stale = folder!(@pending <> Ecto.UUID.generate())
      full = folder!(@pending <> Ecto.UUID.generate())
      fresh = folder!(@pending <> Ecto.UUID.generate())

      Repo.update_all(from(f in Folder, where: f.uuid in ^[stale.uuid, full.uuid]),
        set: [inserted_at: old]
      )

      record!("spec.pdf", %{folder_uuid: full.uuid})

      actions = plan()
      assert [%{op: :trash}] = of(actions, :pending, stale.name)
      assert [%{op: :report, counts: {1, 0}, reason: reason}] = of(actions, :pending, full.name)
      assert reason =~ "spec.pdf"
      assert of(actions, :pending, fresh.name) == []
    end
  end
end
