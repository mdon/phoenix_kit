defmodule PhoenixKit.Modules.Storage.ViewerFilterTest do
  @moduledoc """
  A restricted viewer's view of a site library (`:viewer_uuid`), at the data
  layer: every listing Media reads — files, folders, the tree, search, counts,
  trash, orphans — shows only what is theirs: files they uploaded, folders they
  created or that hold their files, and those folders' ancestors. No viewer means
  no restriction, which is every other caller.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth

  defp user!(tag) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "viewer-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp folder!(name, parent, creator) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: name,
        parent_uuid: parent && parent.uuid,
        user_uuid: creator.uuid
      })

    folder
  end

  defp file!(name, owner, folder \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: name,
        file_name: "f-#{n}.png",
        file_path: "x/#{n}.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: owner.uuid,
        folder_uuid: folder && folder.uuid
      })

    file
  end

  setup do
    alice = user!("alice")
    bob = user!("bob")
    admin = user!("admin")

    # admin made the structure:
    #   Events/            holds alice's and bob's photos
    #     2026/            holds only alice's
    #   Customers/         holds only bob's
    #   Private/           holds only bob's, with a sub folder Acme/ holding bob's
    events = folder!("Events", nil, admin)
    year = folder!("2026", events, admin)
    customers = folder!("Customers", nil, admin)
    private = folder!("Private", nil, admin)
    acme = folder!("Acme", private, admin)
    # alice made one of her own, empty
    mine = folder!("Mine", nil, alice)

    a_events = file!("alice-events.png", alice, events)
    b_events = file!("bob-events.png", bob, events)
    a_year = file!("alice-2026.png", alice, year)
    b_customers = file!("bob-customers.png", bob, customers)
    b_acme = file!("bob-acme.png", bob, acme)
    a_root = file!("alice-root.png", alice)
    b_root = file!("bob-root.png", bob)

    %{
      alice: alice,
      bob: bob,
      folders: %{
        events: events,
        year: year,
        customers: customers,
        private: private,
        acme: acme,
        mine: mine
      },
      files: %{
        a_events: a_events,
        b_events: b_events,
        a_year: a_year,
        b_customers: b_customers,
        b_acme: b_acme,
        a_root: a_root,
        b_root: b_root
      }
    }
  end

  defp names(folders), do: folders |> Enum.map(& &1.name) |> Enum.sort()
  defp uuids(files), do: files |> Enum.map(& &1.uuid) |> Enum.sort()
  defp opts(viewer), do: [viewer_uuid: viewer.uuid]

  describe "files" do
    test "the library listing is the viewer's own", ctx do
      {files, total} = Storage.list_files_in_scope(nil, opts(ctx.alice) ++ [per_page: 50])

      assert uuids(files) ==
               uuids([ctx.files.a_events, ctx.files.a_year, ctx.files.a_root])

      assert total == 3
    end

    test "with no viewer everything is listed", ctx do
      {files, _total} = Storage.list_files_in_scope(nil, per_page: 50)

      assert MapSet.subset?(
               MapSet.new(Map.values(ctx.files), & &1.uuid),
               MapSet.new(files, & &1.uuid)
             )
    end

    test "a folder's listing and its search show only the viewer's files", ctx do
      {files, total} =
        Storage.list_files_in_scope(
          nil,
          opts(ctx.alice) ++ [folder_uuid: ctx.folders.events.uuid]
        )

      assert uuids(files) == [ctx.files.a_events.uuid]
      assert total == 1

      {found, _} = Storage.list_files_in_scope(nil, opts(ctx.alice) ++ [search: "bob"])
      assert found == []

      {found, _} = Storage.list_files_in_scope(nil, opts(ctx.alice) ++ [search: "alice"])
      assert length(found) == 3
    end

    test "a folder holding only someone else's files lists nothing", ctx do
      {files, total} =
        Storage.list_files_in_scope(
          nil,
          opts(ctx.alice) ++ [folder_uuid: ctx.folders.customers.uuid]
        )

      assert {files, total} == {[], 0}
    end
  end

  describe "folders" do
    test "the root shows the folders that are hers, or lead to hers", ctx do
      assert names(Storage.list_folders(nil, nil, opts(ctx.alice))) == ["Events", "Mine"]

      assert names(Storage.list_folders(nil, nil, opts(ctx.bob))) == [
               "Customers",
               "Events",
               "Private"
             ]
    end

    test "with no viewer every folder shows", _ctx do
      assert names(Storage.list_folders(nil, nil, [])) ==
               Enum.sort(["Events", "Customers", "Private", "Mine"] ++ existing_root_names())
    end

    test "children: the ones that lead to her files", ctx do
      assert names(Storage.list_folders(ctx.folders.events.uuid, nil, opts(ctx.alice))) == [
               "2026"
             ]

      assert names(Storage.list_folders(ctx.folders.private.uuid, nil, opts(ctx.alice))) == []
      assert names(Storage.list_folders(ctx.folders.private.uuid, nil, opts(ctx.bob))) == ["Acme"]
    end

    test "an ancestor appears for a file deep beneath it", ctx do
      # bob's only file in Private is in Acme, so Private is shown to lead there.
      assert "Private" in names(Storage.list_folders(nil, nil, opts(ctx.bob)))
      assert ctx.folders.acme.uuid in Storage.viewer_folder_uuids(ctx.bob.uuid)
    end

    test "the tree is pruned the same way", ctx do
      tree = Storage.list_folder_tree(nil, opts(ctx.alice))

      assert tree |> Enum.map(& &1.folder.name) |> Enum.sort() == ["Events", "Mine"]
      events = Enum.find(tree, &(&1.folder.name == "Events"))
      assert Enum.map(events.children, & &1.folder.name) == ["2026"]
    end

    test "search finds only visible folders", ctx do
      assert Storage.search_folders("Customers", nil, nil, opts(ctx.alice)) == []
      assert names(Storage.search_folders("Customers", nil, nil, opts(ctx.bob))) == ["Customers"]
      assert names(Storage.search_folders("Mine", nil, nil, opts(ctx.alice))) == ["Mine"]
    end

    test "viewer_can_see_folder?/3 agrees", ctx do
      assert Storage.viewer_can_see_folder?(ctx.alice.uuid, ctx.folders.year.uuid, nil)
      refute Storage.viewer_can_see_folder?(ctx.alice.uuid, ctx.folders.customers.uuid, nil)
      assert Storage.viewer_can_see_folder?(nil, ctx.folders.customers.uuid, nil)
    end
  end

  describe "trash" do
    test "a viewer's trash is their own files', and so are its counts", ctx do
      {:ok, _} = Storage.trash_file(ctx.files.a_events)
      {:ok, _} = Storage.trash_file(ctx.files.b_events)

      assert uuids(Storage.list_trashed_files(nil, opts(ctx.alice))) == [ctx.files.a_events.uuid]
      assert Storage.count_trashed_files(nil, opts(ctx.alice)) == 1
      assert Storage.count_trashed_files(nil, []) >= 2
    end

    test "a trashed folder is shown to her only if it is hers to see", ctx do
      {:ok, _} = Storage.trash_folder(ctx.folders.customers)
      {:ok, _} = Storage.trash_folder(ctx.folders.mine)

      assert Storage.count_trashed_folders(nil, opts(ctx.alice)) == 1

      assert ["Mine"] ==
               nil |> Storage.list_trashed_folders(opts(ctx.alice)) |> names()
    end

    test "emptying the trash removes the viewer's files only", ctx do
      {:ok, _} = Storage.trash_file(ctx.files.a_root)
      {:ok, _} = Storage.trash_file(ctx.files.b_root)

      Storage.empty_trash(nil, opts(ctx.alice))

      assert Storage.get_file(ctx.files.a_root.uuid) == nil
      assert %{status: "trashed"} = Storage.get_file(ctx.files.b_root.uuid)
    end
  end

  describe "orphans" do
    test "counted and listed for the viewer's own files only", ctx do
      own = Storage.count_orphaned_files(nil, opts(ctx.alice))
      all = Storage.count_orphaned_files(nil, [])

      assert own == Enum.count(Storage.find_orphaned_files(opts(ctx.alice)))
      assert own < all

      assert Enum.all?(
               Storage.find_orphaned_files(opts(ctx.alice)),
               &(&1.user_uuid == ctx.alice.uuid)
             )
    end
  end

  describe "viewer_can_see_file?/2" do
    test "only the uploader's", ctx do
      assert Storage.viewer_can_see_file?(ctx.alice.uuid, ctx.files.a_events)
      refute Storage.viewer_can_see_file?(ctx.alice.uuid, ctx.files.b_events)
      assert Storage.viewer_can_see_file?(nil, ctx.files.b_events)
    end
  end

  defp existing_root_names do
    # Folders the test database already holds at the root (other tests are rolled back).
    Storage.list_folders(nil, nil, [])
    |> names()
    |> Enum.reject(&(&1 in ["Events", "Customers", "Private", "Mine"]))
  end
end
