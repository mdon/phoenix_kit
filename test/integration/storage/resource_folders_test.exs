defmodule PhoenixKit.Integration.Storage.ResourceFoldersTest do
  use PhoenixKit.DataCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, ResourceFolders}
  alias PhoenixKit.Users.Auth

  defmodule Hooks do
    @moduledoc false
    # The subject tells the hook what to do, so one module covers every answer.
    def parent(_kind, _actor, {:answer, answer}), do: answer
    def parent(_kind, _actor, :raise), do: raise("secret-payload")
    def parent(_kind, _actor, :exit), do: exit({:boom, %{token: "secret-payload"}})
    def parent(_kind, _actor, :throw), do: throw({:token, "secret-payload"})
    def parent(kind, actor, subject), do: {:ok, {kind, actor, subject}}

    def name(:raise, _actor), do: raise("secret-payload")
    def name({:answer, answer}, _actor), do: answer
  end

  defmodule TwoArityHooks do
    @moduledoc false
    def parent(:item, _actor), do: {:ok, "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"}
  end

  defp app do
    app = :"resource_folders_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.get_all_env(app)
      |> Keyword.keys()
      |> Enum.each(&Application.delete_env(app, &1))
    end)

    app
  end

  defp folder!(name, parent \\ nil) do
    {:ok, folder} = Storage.create_folder(%{name: name, parent_uuid: parent && parent.uuid})
    folder
  end

  defp trash!(%Folder{} = folder) do
    folder
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp file!(folder, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %StorageFile{
      original_file_name: "f#{n}.jpg",
      file_name: "f#{n}.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "sha256:rf-#{n}",
      user_file_checksum: "user-sha256:rf-#{n}",
      size: 10,
      status: "active",
      folder_uuid: folder && folder.uuid,
      user_uuid: user_uuid()
    }

    Repo.insert!(struct(base, attrs))
  end

  defp user_uuid do
    Process.get(:rf_user) ||
      (
        {:ok, user} =
          Auth.register_user(%{
            email: "rf-#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:rf_user, user.uuid)
        user.uuid
      )
  end

  defp link!(folder, file), do: {:ok, _} = Storage.create_folder_link(folder.uuid, file.uuid)
  defp name, do: "rf-#{System.unique_integer([:positive])}"
  defp uuids(files), do: Enum.map(files, & &1.uuid)

  describe "parent_hook/4" do
    test "unconfigured, answered, root, and the 2-arity fallback" do
      app = app()
      assert ResourceFolders.parent_hook(app, :item, nil, nil) == :unconfigured

      Application.put_env(app, :attachments_parent_folder, {Hooks, :parent})
      uuid = Ecto.UUID.generate()
      assert ResourceFolders.parent_hook(app, :item, "a", {:answer, {:ok, uuid}}) == {:ok, uuid}
      assert ResourceFolders.parent_hook(app, :item, "a", {:answer, nil}) == {:ok, nil}
      assert ResourceFolders.parent_hook(app, :item, "a", {:answer, {:ok, nil}}) == {:ok, nil}

      Application.put_env(app, :attachments_parent_folder, {TwoArityHooks, :parent})

      assert ResourceFolders.parent_hook(app, :item, "a", :ignored) ==
               {:ok, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"}
    end

    test "every kind of failure is an error, never the root" do
      app = app()
      Application.put_env(app, :attachments_parent_folder, {Hooks, :parent})

      assert {:error, %RuntimeError{}} = ResourceFolders.parent_hook(app, :item, nil, :raise)
      assert {:error, {:exit, _}} = ResourceFolders.parent_hook(app, :item, nil, :exit)
      assert {:error, {:throw, _}} = ResourceFolders.parent_hook(app, :item, nil, :throw)

      assert {:error, {:bad_answer, _}} =
               ResourceFolders.parent_hook(app, :item, nil, {:answer, {:ok, "not-a-uuid"}})

      # Sixteen bytes: `Ecto.UUID.cast/1` would take it as a raw uuid.
      assert {:error, {:bad_answer, _}} =
               ResourceFolders.parent_hook(app, :item, nil, {:answer, {:ok, "folder-uuid-1234"}})

      assert {:error, {:bad_answer, _}} =
               ResourceFolders.parent_hook(app, :item, nil, {:answer, :root})

      assert {:error, :nope} =
               ResourceFolders.parent_hook(app, :item, nil, {:answer, {:error, :nope}})

      Application.put_env(app, :attachments_parent_folder, {Hooks, :missing})
      assert {:error, {:not_exported, _}} = ResourceFolders.parent_hook(app, :item, nil, nil)

      Application.put_env(app, :attachments_parent_folder, "Hooks.parent")
      assert {:error, {:bad_config, _}} = ResourceFolders.parent_hook(app, :item, nil, nil)
    end

    test "parent_uuid/4 falls back to the root and logs only the failure's shape" do
      app = app()
      Application.put_env(app, :attachments_parent_folder, {Hooks, :parent})

      log =
        capture_log(fn ->
          ResourceFolders.parent_uuid(app, :item, nil, {:answer, {:ok, "secret-not-a-uuid"}})
          ResourceFolders.parent_uuid(app, :item, nil, {:answer, :not_an_answer})
        end)

      assert log =~ "{:ok, a string that is not a uuid}"
      assert log =~ ":not_an_answer"
      refute log =~ "secret"

      for subject <- [:raise, :exit, :throw] do
        log =
          capture_log(fn ->
            assert ResourceFolders.parent_uuid(app, :item, nil, subject) == nil
          end)

        assert log =~ "attachments_parent_folder hook failed"
        refute log =~ "secret"
      end
    end
  end

  describe "name_hook/3" do
    test "trims a name, and tells a failure from no answer" do
      app = app()
      assert ResourceFolders.name_hook(app, {:answer, {:ok, "x"}}, nil) == :unconfigured

      Application.put_env(app, :attachments_folder_name, {Hooks, :name})

      assert ResourceFolders.name_hook(app, {:answer, {:ok, "  Kitchen  "}}, nil) ==
               {:ok, "Kitchen"}

      assert ResourceFolders.name_hook(app, {:answer, nil}, nil) == {:ok, nil}

      assert {:error, {:bad_answer, _}} =
               ResourceFolders.name_hook(app, {:answer, {:ok, "  "}}, nil)

      assert {:error, %RuntimeError{}} = ResourceFolders.name_hook(app, :raise, nil)

      log = capture_log(fn -> assert ResourceFolders.host_name(app, :raise, nil) == nil end)
      refute log =~ "secret"
    end
  end

  describe "finding folders" do
    test "find_under/2 sees live folders directly under the parent only" do
      parent = folder!(name())
      n = name()
      assert ResourceFolders.find_under(n, parent.uuid) == nil

      trash!(folder!(n, parent))
      assert ResourceFolders.find_under(n, parent.uuid) == nil

      live = folder!(n, parent)
      assert ResourceFolders.find_under(n, parent.uuid).uuid == live.uuid
      assert ResourceFolders.find_under(n, nil) == nil
      assert ResourceFolders.find_under(n, "root") == nil
      assert ResourceFolders.live_folder(binary_part(Ecto.UUID.dump!(live.uuid), 0, 16)) == nil
    end

    test "find_named/3 prefers the parent, then the root, then (anywhere) elsewhere" do
      parent = folder!(name())
      elsewhere = folder!(name())
      n = name()

      far = folder!(n, elsewhere)
      assert ResourceFolders.find_named(n, parent.uuid) == nil
      assert ResourceFolders.find_named(n, parent.uuid, anywhere: true).uuid == far.uuid

      root = folder!(n)
      assert ResourceFolders.find_named(n, parent.uuid, anywhere: true).uuid == root.uuid
      assert ResourceFolders.find_named(n, nil).uuid == root.uuid

      near = folder!(n, parent)
      assert ResourceFolders.find_named(n, parent.uuid).uuid == near.uuid
      assert ResourceFolders.find_named(n, parent.uuid, anywhere: true).uuid == near.uuid
    end

    test "find_named/3 picks the oldest of several elsewhere, and skips trashed ones" do
      a = folder!(name())
      b = folder!(name())
      n = name()
      _second = folder!(n, b)

      # Older by a clear margin: two folders made in the same millisecond
      # would order by their random UUIDv7 tails.
      first =
        folder!(n, a)
        |> Ecto.Changeset.change(inserted_at: ~U[2026-01-01 00:00:00Z])
        |> Repo.update!()

      assert ResourceFolders.find_named(n, nil, anywhere: true).uuid == first.uuid

      trash!(first)
      refute ResourceFolders.find_named(n, nil, anywhere: true).uuid == first.uuid
    end

    test "find_named_all/3 answers many names in one call" do
      parent = folder!(name())
      [n1, n2, n3] = [name(), name(), name()]
      f1 = folder!(n1, parent)
      f2 = folder!(n2)

      assert %{^n1 => %{uuid: u1}, ^n2 => %{uuid: u2}} =
               found = ResourceFolders.find_named_all([n1, n2, n3], parent.uuid)

      assert {u1, u2} == {f1.uuid, f2.uuid}
      refute Map.has_key?(found, n3)
      assert ResourceFolders.find_named_all([], nil) == %{}
    end

    test "resolve/1 goes pointer, host name (unless claimed), deterministic name" do
      parent = folder!(name())
      [host, det] = [name(), name()]
      host_folder = folder!(host, parent)
      det_folder = folder!(det, parent)
      pointed = folder!(name())

      opts = [parent: parent.uuid, host_name: host, name: det]
      assert ResourceFolders.resolve([pointer: pointed.uuid] ++ opts).uuid == pointed.uuid

      trash!(pointed)
      assert ResourceFolders.resolve([pointer: pointed.uuid] ++ opts).uuid == host_folder.uuid
      assert ResourceFolders.resolve([pointer: "garbage"] ++ opts).uuid == host_folder.uuid

      claimed = [claimed?: fn folder -> folder.uuid == host_folder.uuid end]
      assert ResourceFolders.resolve(opts ++ claimed).uuid == det_folder.uuid

      assert ResourceFolders.resolve(parent: parent.uuid, name: name()) == nil
      assert ResourceFolders.resolve([]) == nil
    end

    test "resolve/1 skips the claim query when the host name is the deterministic one" do
      parent = folder!(name())
      det = name()
      det_folder = folder!(det, parent)
      me = self()

      assert ResourceFolders.resolve(
               parent: parent.uuid,
               host_name: det,
               name: det,
               claimed?: fn _ -> send(me, :claim_checked) end
             ).uuid == det_folder.uuid

      refute_received :claim_checked
    end
  end

  describe "claimed?/3" do
    test "another record pointing at the folder claims it; the record itself does not" do
      folder = folder!(name())
      other = folder!(name())
      holder = file!(nil, %{data: %{"files_folder_uuid" => folder.uuid}})

      pointers = [{StorageFile, {:data, "files_folder_uuid"}}]
      assert ResourceFolders.claimed?(folder.uuid, nil, pointers)
      refute ResourceFolders.claimed?(folder.uuid, holder.uuid, pointers)
      refute ResourceFolders.claimed?(other.uuid, nil, pointers)

      home = file!(other)
      assert ResourceFolders.claimed?(other.uuid, nil, [{StorageFile, {:column, :folder_uuid}}])

      refute ResourceFolders.claimed?(other.uuid, home.uuid, [
               {StorageFile, {:column, :folder_uuid}}
             ])
    end

    test "fails closed" do
      folder = folder!(name())

      capture_log(fn ->
        assert ResourceFolders.claimed?(folder.uuid, nil, [
                 {StorageFile, {:column, :no_such_field}}
               ])
      end)
    end
  end

  describe "ensure/4" do
    test "finds the folder, or creates it under the parent" do
      parent = folder!(name())
      n = name()
      assert {:ok, %Folder{} = created} = ResourceFolders.ensure(n, parent.uuid, user_uuid())
      assert {created.parent_uuid, created.user_uuid} == {parent.uuid, user_uuid()}
      assert {:ok, again} = ResourceFolders.ensure(n, parent.uuid, nil)
      assert again.uuid == created.uuid
    end

    test "a create lost to a concurrent one takes the winner" do
      parent = folder!(name())
      n = name()
      winner = folder!(n, parent)

      # The first lookup misses (the other create has not landed yet), the
      # one after the refused insert sees it.
      counter = :counters.new(1, [])

      lookup = fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: nil,
          else: ResourceFolders.find_under(n, parent.uuid)
      end

      assert {:ok, found} = ResourceFolders.ensure(n, parent.uuid, nil, lookup: lookup)
      assert found.uuid == winner.uuid
      assert :counters.get(counter, 1) == 2
    end

    test "a host name another record's folder has falls back to the uuid-bearing name" do
      parent = folder!(name())
      [host, det] = [name(), name()]
      _theirs = folder!(host, parent)
      not_mine = fn -> nil end

      assert {:ok, mine} =
               ResourceFolders.ensure(host, parent.uuid, nil,
                 lookup: not_mine,
                 fallback_name: det
               )

      assert {mine.name, mine.parent_uuid} == {det, parent.uuid}

      assert {:error, %Ecto.Changeset{}} =
               ResourceFolders.ensure(host, parent.uuid, nil, lookup: not_mine)
    end

    test "a taken host name falls back without a refused insert, so a transaction survives" do
      parent = folder!(name())
      [host, det] = [name(), name()]
      _theirs = folder!(host, parent)

      assert {:ok, {:ok, mine}} =
               Repo.transaction(fn ->
                 result =
                   ResourceFolders.ensure(host, parent.uuid, nil,
                     lookup: fn -> nil end,
                     fallback_name: det
                   )

                 # Still usable: a refused insert would have aborted it.
                 assert ResourceFolders.find_under(det, parent.uuid)
                 result
               end)

      assert mine.name == det
    end

    test "a refused insert inside a transaction leaves the transaction usable" do
      parent = folder!(name())
      n = name()
      _taken = folder!(n, parent)

      assert {:ok, :still_usable} =
               Repo.transaction(fn ->
                 assert {:error, %Ecto.Changeset{}} =
                          ResourceFolders.ensure(n, parent.uuid, nil, lookup: fn -> nil end)

                 assert ResourceFolders.find_under(n, parent.uuid)
                 :still_usable
               end)
    end

    test "with :claim, the folder is recorded as the record's before anyone else looks" do
      parent = folder!(name())
      host = name()
      pointer = {:data, "files_folder_uuid"}
      pointers = [{StorageFile, pointer}]
      [a, b] = [file!(nil), file!(nil)]

      ensure_for = fn record ->
        ResourceFolders.ensure(host, parent.uuid, nil,
          lookup: fn ->
            ResourceFolders.resolve(
              parent: parent.uuid,
              host_name: host,
              name: "det-" <> record.uuid,
              claimed?: &ResourceFolders.claimed?(&1.uuid, record.uuid, pointers)
            )
          end,
          fallback_name: "det-" <> record.uuid,
          claim: &ResourceFolders.write_pointer(StorageFile, record.uuid, pointer, &1.uuid)
        )
      end

      assert {:ok, %Folder{name: ^host} = theirs} = ensure_for.(a)
      assert Repo.get!(StorageFile, a.uuid).data["files_folder_uuid"] == theirs.uuid

      assert {:ok, mine} = ensure_for.(b)
      assert mine.name == "det-" <> b.uuid
      assert Repo.get!(StorageFile, b.uuid).data["files_folder_uuid"] == mine.uuid

      # The same record again (another tab) converges on its own folder.
      assert ensure_for.(a) == {:ok, theirs}
    end

    test "a claim that fails rolls the create back" do
      n = name()

      capture_log(fn ->
        assert {:error, :nope} =
                 ResourceFolders.ensure(n, nil, nil, claim: fn _ -> {:error, :nope} end)
      end)

      refute ResourceFolders.find_under(n, nil)
    end

    test "never raises" do
      log =
        capture_log(fn ->
          assert {:error, %RuntimeError{}} =
                   ResourceFolders.ensure(name(), nil, nil, lookup: fn -> raise "down" end)
        end)

      assert log =~ "ensure folder failed"
    end
  end

  describe "name_pending/4" do
    test "renames a pending folder in place, falling back when the name is taken" do
      parent = folder!(name())
      [det, host] = [name(), name()]

      pending = folder!("pending-" <> name(), parent)
      assert ResourceFolders.name_pending(pending.uuid, "pending-", det) == :ok
      renamed = Repo.get!(Folder, pending.uuid)
      assert {renamed.name, renamed.parent_uuid} == {det, parent.uuid}

      _theirs = folder!(host, parent)
      pending = folder!("pending-" <> name(), parent)

      fallback = name() <> "-fb"

      assert ResourceFolders.name_pending(pending.uuid, "pending-", host, fallback_name: fallback) ==
               :ok

      assert Repo.get!(Folder, pending.uuid).name == fallback
    end

    test "moves the folder only when told where" do
      parent = folder!(name())
      pending = folder!("pending-" <> name())

      assert ResourceFolders.name_pending(pending.uuid, "pending-", name(), move_to: parent.uuid) ==
               :ok

      assert Repo.get!(Folder, pending.uuid).parent_uuid == parent.uuid

      nested = folder!("pending-" <> name(), parent)
      assert ResourceFolders.name_pending(nested.uuid, "pending-", name(), move_to: nil) == :ok
      assert Repo.get!(Folder, nested.uuid).parent_uuid == nil

      kept = folder!("pending-" <> name(), parent)
      assert ResourceFolders.name_pending(kept.uuid, "pending-", name()) == :ok
      assert Repo.get!(Folder, kept.uuid).parent_uuid == parent.uuid
    end

    test "leaves a folder that is not pending alone" do
      folder = folder!("kept-" <> name())
      assert ResourceFolders.name_pending(folder.uuid, "pending-", name()) == :ok
      assert Repo.get!(Folder, folder.uuid).name == folder.name
      assert ResourceFolders.name_pending(nil, "pending-", name()) == :ok
    end
  end

  describe "write_pointer/4" do
    test "sets and clears a JSONB key, leaving the rest of the map" do
      record = file!(nil, %{data: %{"keep" => "me"}})
      folder = folder!(name())
      pointer = {:data, "files_folder_uuid"}

      assert ResourceFolders.write_pointer(StorageFile, record.uuid, pointer, folder.uuid) == :ok

      assert Repo.get!(StorageFile, record.uuid).data == %{
               "keep" => "me",
               "files_folder_uuid" => folder.uuid
             }

      assert ResourceFolders.write_pointer(StorageFile, record.uuid, pointer, nil) == :ok
      assert Repo.get!(StorageFile, record.uuid).data == %{"keep" => "me"}
    end

    test "sets a column, and reports a record that is not there" do
      record = file!(nil)
      folder = folder!(name())

      assert ResourceFolders.write_pointer(
               StorageFile,
               record.uuid,
               {:column, :folder_uuid},
               folder.uuid
             ) == :ok

      assert Repo.get!(StorageFile, record.uuid).folder_uuid == folder.uuid

      assert ResourceFolders.write_pointer(
               StorageFile,
               Ecto.UUID.generate(),
               {:column, :folder_uuid},
               nil
             ) ==
               {:error, :not_found}
    end
  end

  describe "purge_named/1" do
    test "deletes every folder of that name, live or trashed, and only those" do
      elsewhere = folder!(name())
      n = name()
      live = folder!(n)
      trashed = trash!(folder!(n, elsewhere))
      bystander = folder!(name())
      file!(live)

      shared = file!(live)
      link!(bystander, shared)

      assert ResourceFolders.purge_named(n) == :ok
      refute Repo.get(Folder, live.uuid)
      refute Repo.get(Folder, trashed.uuid)
      assert Repo.get(Folder, bystander.uuid)
      assert Repo.get!(StorageFile, shared.uuid).folder_uuid == bystander.uuid
    end
  end

  describe "files in a folder" do
    setup do
      folder = folder!(name())
      other = folder!(name())
      old = file!(folder)
      linked = file!(other)
      link!(folder, linked)
      doc = file!(folder, %{file_type: "document", mime_type: "application/pdf"})
      _trashed = file!(folder, %{status: "trashed"})
      _system = file!(folder, %{system_managed: true})
      _stranger = file!(other)

      # Distinct timestamps, so the order assertions mean something.
      for {file, s} <- [{old, 1}, {linked, 2}, {doc, 3}] do
        at = ~U[2026-01-01 00:00:00Z] |> DateTime.add(s)
        file |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
      end

      %{folder: folder, other: other, old: old, linked: linked, doc: doc}
    end

    test "list_files/2 holds home and linked files, live ones only", c do
      assert uuids(ResourceFolders.list_files(c.folder.uuid)) == uuids([c.doc, c.linked, c.old])

      assert uuids(ResourceFolders.list_files(c.folder.uuid, order: :oldest)) ==
               uuids([c.old, c.linked, c.doc])

      assert uuids(ResourceFolders.list_files(c.folder.uuid, only: :images, order: :oldest)) ==
               uuids([c.old, c.linked])

      assert uuids(ResourceFolders.list_files(c.folder.uuid, only: :non_images)) == [c.doc.uuid]

      assert uuids(ResourceFolders.list_files(c.folder.uuid, only: {:type, "document"})) ==
               [c.doc.uuid]

      assert uuids(ResourceFolders.list_files(c.folder.uuid, only: {:not_type, "document"})) ==
               uuids([c.linked, c.old])

      assert length(ResourceFolders.list_files(c.folder.uuid, limit: 1)) == 1
      assert ResourceFolders.list_files(nil) == []

      assert Repo.aggregate(ResourceFolders.files_query(c.folder.uuid), :count) == 3
    end

    test "files_by_folder/2 maps each folder to what it holds", c do
      empty = folder!(name())
      by_folder = ResourceFolders.files_by_folder([c.folder.uuid, c.other.uuid, empty.uuid])

      assert uuids(by_folder[c.folder.uuid]) == uuids([c.doc, c.linked, c.old])
      assert c.linked.uuid in uuids(by_folder[c.other.uuid])
      refute Map.has_key?(by_folder, empty.uuid)

      assert uuids(ResourceFolders.files_by_folder([c.folder.uuid], only: :images)[c.folder.uuid]) ==
               uuids([c.linked, c.old])
    end

    test "count_by_folder/2 counts what list_files/2 lists", c do
      empty = folder!(name())
      # A link into the file's own home folder: listed once, counted once.
      link!(c.folder, c.old)

      counts = ResourceFolders.count_by_folder([c.folder.uuid, c.other.uuid, empty.uuid])
      assert counts[c.folder.uuid] == length(ResourceFolders.list_files(c.folder.uuid))
      assert counts[c.other.uuid] == length(ResourceFolders.list_files(c.other.uuid))
      refute Map.has_key?(counts, empty.uuid)

      assert ResourceFolders.count_by_folder([c.folder.uuid], only: :non_images) ==
               %{c.folder.uuid => 1}
    end

    test "holds_file?/3 authorizes only the folder's own live files", c do
      assert ResourceFolders.holds_file?(c.folder.uuid, c.old.uuid)
      assert ResourceFolders.holds_file?(c.folder.uuid, c.linked.uuid, only: :images)
      refute ResourceFolders.holds_file?(c.folder.uuid, c.doc.uuid, only: :images)
      refute ResourceFolders.holds_file?(c.other.uuid, c.old.uuid)
      refute ResourceFolders.holds_file?(nil, c.old.uuid)
      refute ResourceFolders.holds_file?(c.folder.uuid, "garbage")
    end

    test "point_at/6 writes the pointer only to a file the folder holds", c do
      record = file!(nil, %{data: %{"keep" => "me"}})
      pointer = {:data, "avatar_uuid"}
      point = &ResourceFolders.point_at(StorageFile, record.uuid, pointer, &1, c.folder.uuid, &2)

      assert point.(c.linked.uuid, only: :images) == :ok

      assert Repo.get!(StorageFile, record.uuid).data == %{
               "keep" => "me",
               "avatar_uuid" => c.linked.uuid
             }

      for refused <- [c.doc.uuid, Ecto.UUID.generate(), "garbage"] do
        assert point.(refused, only: :images) == {:error, :not_held}
      end

      trashed = file!(c.folder, %{status: "trashed", file_type: "image"})
      assert point.(trashed.uuid, []) == {:error, :not_held}

      assert ResourceFolders.point_at(
               StorageFile,
               Ecto.UUID.generate(),
               pointer,
               c.old.uuid,
               c.folder.uuid
             ) ==
               {:error, :not_found}

      assert Repo.get!(StorageFile, record.uuid).data["avatar_uuid"] == c.linked.uuid
    end
  end

  describe "pointers" do
    test "pointer_value/2 reads a map key or a column, and only a uuid" do
      uuid = Ecto.UUID.generate()

      assert ResourceFolders.pointer_value(
               %{metadata: %{"avatar_uuid" => uuid}},
               {:metadata, "avatar_uuid"}
             ) == uuid

      assert ResourceFolders.pointer_value(%{metadata: nil}, {:metadata, "avatar_uuid"}) == nil
      assert ResourceFolders.pointer_value(%{data: %{"x" => "garbage"}}, {:data, "x"}) == nil
      assert ResourceFolders.pointer_value(%{folder_uuid: uuid}, {:column, :folder_uuid}) == uuid
    end

    test "pointed_file/2 answers only a live file" do
      live = file!(nil)
      trashed = file!(nil, %{status: "trashed"})
      pointer = {:data, "p"}

      assert ResourceFolders.pointed_file(%{data: %{"p" => live.uuid}}, pointer).uuid == live.uuid
      assert ResourceFolders.pointed_file(%{data: %{"p" => trashed.uuid}}, pointer) == nil
      assert ResourceFolders.pointed_file(%{data: %{"p" => Ecto.UUID.generate()}}, pointer) == nil
      assert ResourceFolders.pointed_file(%{data: %{}}, pointer) == nil
    end
  end

  describe "attach/2, place_stored/2, detach/2" do
    test "attach adopts, links, and reports what is already there" do
      folder = folder!(name())
      other = folder!(name())
      loose = file!(nil)
      homed = file!(other)

      assert ResourceFolders.attach(loose.uuid, folder.uuid) == {:ok, :adopted}
      assert Repo.get!(StorageFile, loose.uuid).folder_uuid == folder.uuid
      assert ResourceFolders.attach(loose.uuid, folder.uuid) == {:ok, :already_attached}

      assert ResourceFolders.attach(homed, folder.uuid) == {:ok, :linked}
      assert Repo.get!(StorageFile, homed.uuid).folder_uuid == other.uuid
      assert ResourceFolders.attach(homed, folder.uuid) == {:ok, :already_attached}
    end

    test "attach refuses a trashed file" do
      folder = folder!(name())
      trashed = file!(nil, %{status: "trashed"})
      assert ResourceFolders.attach(trashed, folder.uuid) == {:error, :file_trashed}
    end

    test "attach refuses a folder that is not live, and a missing file" do
      trashed = trash!(folder!(name()))
      loose = file!(nil)
      assert ResourceFolders.attach(loose, trashed.uuid) == {:error, :folder_unavailable}
      assert ResourceFolders.attach(loose, Ecto.UUID.generate()) == {:error, :folder_unavailable}
      assert Repo.get!(StorageFile, loose.uuid).folder_uuid == nil

      assert ResourceFolders.attach(Ecto.UUID.generate(), folder!(name()).uuid) ==
               {:error, :not_found}
    end

    test "place_stored restores a trashed duplicate and reports one already here" do
      folder = folder!(name())
      trashed = file!(nil, %{status: "trashed"})
      assert {:ok, _} = ResourceFolders.place_stored({:ok, trashed, :duplicate}, folder.uuid)
      restored = Repo.get!(StorageFile, trashed.uuid)
      assert {restored.status, restored.folder_uuid} == {"active", folder.uuid}

      assert {:already_attached, _} =
               ResourceFolders.place_stored({:ok, restored, :duplicate}, folder.uuid)

      assert {:ok, _} = ResourceFolders.place_stored({:ok, restored}, folder.uuid)
      assert ResourceFolders.place_stored({:error, :too_big}, folder.uuid) == {:error, :too_big}
    end

    test "attach and detach decide from the file's current row, not a stale struct" do
      [a, b, c] = [folder!(name()), folder!(name()), folder!(name())]

      loose = file!(nil)
      assert ResourceFolders.attach(loose.uuid, a.uuid) == {:ok, :adopted}
      # `loose` still says it has no home; attaching it elsewhere must link, not move it.
      assert ResourceFolders.attach(loose, b.uuid) == {:ok, :linked}
      assert Repo.get!(StorageFile, loose.uuid).folder_uuid == a.uuid

      shared = file!(c)
      link!(b, shared)
      assert ResourceFolders.detach(shared, c.uuid) == {:ok, :rehomed}
      # A second removal still holding the old struct: the file lives in b now.
      assert ResourceFolders.detach(shared, c.uuid) == {:ok, :absent}
      assert %{status: "active", folder_uuid: home} = Repo.get!(StorageFile, shared.uuid)
      assert home == b.uuid
    end

    test "a restored duplicate whose attach fails goes back to the trash" do
      trashed_target = trash!(folder!(name()))
      file = file!(nil, %{status: "trashed"})

      assert ResourceFolders.place_stored({:ok, file, :duplicate}, trashed_target.uuid) ==
               {:error, :folder_unavailable}

      assert Repo.get!(StorageFile, file.uuid).status == "trashed"
    end

    test "detach unlinks, re-homes, trashes — and never touches a file not here" do
      folder = folder!(name())
      other = folder!(name())

      linked = file!(other)
      link!(folder, linked)
      assert ResourceFolders.detach(linked.uuid, folder.uuid) == {:ok, :unlinked}

      shared = file!(folder)
      link!(other, shared)
      assert ResourceFolders.detach(shared, folder.uuid) == {:ok, :rehomed}
      assert Repo.get!(StorageFile, shared.uuid).folder_uuid == other.uuid

      sole = file!(folder)
      assert ResourceFolders.detach(sole, folder.uuid) == {:ok, :trashed}

      stranger = file!(other)
      assert ResourceFolders.detach(stranger, folder.uuid) == {:ok, :absent}
      assert ResourceFolders.detach(stranger, nil) == {:ok, :absent}
      assert Repo.get!(StorageFile, stranger.uuid).status == "active"
      assert ResourceFolders.detach(Ecto.UUID.generate(), folder.uuid) == {:ok, :absent}
    end
  end
end
