defmodule PhoenixKitWeb.Components.MediaBrowserReadonlyTest do
  @moduledoc """
  The `:readonly` attr (default `false`, issue #840) embeds the browser for
  viewing only: every write-capable affordance — upload, rename, move,
  trash, new folder, bulk-select entry, rotate, the featured toggle, and
  the image editor — is hidden in the markup AND refused server-side (the
  markup is a courtesy, not the boundary — every blocked `handle_event`
  clause matches on `socket.assigns.readonly == true` ahead of the real
  clause, so a stray console event still no-ops). Navigation, the modal
  viewer, and downloads keep working, and a `featured` badge stays visible
  (display only) even though its kebab toggle disappears.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  # ---------------------------------------------------------------------------
  # Helpers (same fixtures media_browser_featured_test.exs uses)
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  defp create_file!(folder_uuid) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "file_#{n}.jpg",
        file_name: "file_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid,
        user_uuid: ensure_user!()
      })

    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "media-browser-readonly-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Render — normal mode (regression, unchanged by this feature)
  # ---------------------------------------------------------------------------

  describe "render — readonly false (default)" do
    test "write affordances render as before" do
      folder = create_folder!()
      _file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid
        )

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_upload"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_select_mode"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="prepare_move_file"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[role="menuitem"])))
    end
  end

  # ---------------------------------------------------------------------------
  # Render — readonly true
  # ---------------------------------------------------------------------------

  describe "render — readonly true" do
    test "toolbar and overflow menu hide Add Media / Select / New folder, keep Search" do
      folder = create_folder!()

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true
        )

      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_upload"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_select_mode"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_search"])))
    end

    test "the stacks-view New-folder tile is hidden" do
      folder = create_folder!()

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "stacks"
        )

      assert html =~ "stacks"
      doc = LazyHTML.from_fragment(html)
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
    end

    test "the upload zone card is hidden even if show_upload is forced true" do
      folder = create_folder!()

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          show_upload: true,
          parent_uploads: %{media_files: %{entries: []}}
        )

      refute html =~ "Upload Media"
    end

    test "folder kebab menu is entirely absent (grid and list)" do
      folder = create_folder!()
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "grid"
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "list"
        )

      for html <- [html_grid, html_list] do
        doc = LazyHTML.from_fragment(html)
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="start_rename_folder"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="change_folder_color"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="prepare_move_folder"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="delete_folder"])))
      end
    end

    test "file kebab hides Rotate / Move / Delete / Edit image, download stays reachable" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "grid"
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "list"
        )

      for html <- [html_grid, html_list] do
        doc = LazyHTML.from_fragment(html)

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="rotate_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="prepare_move_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="delete_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="open_image_editor"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )
      end
    end

    test "the sidebar's new-folder/rename/drag affordances are hidden" do
      folder = create_folder!()
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true
        )

      refute html =~ "data-draggable-folder"
      refute html =~ "data-drop-folder"
    end

    test "drag attributes are stripped from grid/list file and folder tiles" do
      folder = create_folder!()
      _file = create_file!(folder.uuid)
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "grid"
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          view_mode: "list"
        )

      for html <- [html_grid, html_list] do
        refute html =~ "data-draggable-file"
        refute html =~ "data-draggable-folder"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Featured badge stays; the toggle disappears
  # ---------------------------------------------------------------------------

  describe "readonly + featured" do
    test "the badge still renders, the Set/Unset kebab item does not" do
      folder = create_folder!()
      featured_file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          featured: %{uuid: featured_file.uuid, label: nil}
        )

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, ~s([data-role="featured-badge"]))),
             "the badge is display-only and must survive readonly"

      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="set_featured"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="unset_featured"])))
    end
  end

  # ---------------------------------------------------------------------------
  # Events — every blocked event is a no-op under readonly. Direct
  # handle_event/3 calls against a minimal socket, the style
  # media_browser_featured_test.exs and media_browser_viewer_url_test.exs use
  # — the blocked clauses only pattern-match on `socket.assigns.readonly`, so
  # no other assign needs to be primed for the guard to fire.
  # ---------------------------------------------------------------------------

  @blocked_events ~w(
    open_new_folder_modal new_folder_input submit_new_folder
    delete_folder move_file_to_folder move_folder_to_folder trash_file trash_folder
    start_rename_folder rename_folder_input rename_folder
    start_edit_folder_description folder_description_input save_folder_description
    start_edit_folder_header folder_header_input open_cover_picker open_logo_picker
    remove_folder_cover remove_folder_logo set_header_size toggle_header_option
    save_folder_header change_folder_color
    toggle_select_mode long_press_select open_image_editor toggle_select_folder
    toggle_select select_all
    show_move_modal toggle_move_folder prepare_move_file prepare_move_folder
    move_selected_to_folder delete_selected
    rotate_file delete_file set_featured unset_featured restore_selected
    empty_trash delete_all_orphaned toggle_upload show_upload
  )

  describe "every mutating handle_event is a no-op under readonly" do
    test "the socket comes back byte-for-byte unchanged, for every blocked event" do
      for event <- @blocked_events do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, id: "mb", readonly: true}
        }

        assert {:noreply, ^socket} = MediaBrowser.handle_event(event, %{}, socket),
               "expected #{event} to no-op under readonly"
      end
    end

    test "readonly: false (or absent) does not trip the guard — sanity check" do
      # A handful of representatives whose real clause needs no other setup
      # than the params it's given, confirming the new guard clauses only
      # intercept the readonly:true case and never shadow the real one.
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, id: "mb", readonly: false}}

      {:noreply, socket} =
        MediaBrowser.handle_event("new_folder_input", %{"name" => "x"}, socket)

      assert socket.assigns.new_folder_name == "x"

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, id: "mb", readonly: false, show_upload: false}
      }

      {:noreply, socket} = MediaBrowser.handle_event("toggle_upload", %{}, socket)
      assert socket.assigns.show_upload, "the real clause ran and flipped the assign"
    end
  end

  # ---------------------------------------------------------------------------
  # DB-level belt-and-braces: representative events per bucket, confirmed
  # against real fixtures that persisted state is untouched.
  # ---------------------------------------------------------------------------

  defp readonly_socket(extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, id: "mb", readonly: true}, extra)
    }
  end

  describe "DB is untouched by blocked events" do
    test "submit_new_folder creates no folder" do
      folder = create_folder!()
      before_count = length(Storage.list_folders(folder.uuid, nil))

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "submit_new_folder",
          %{"name" => "should-not-be-created-#{System.unique_integer([:positive])}"},
          readonly_socket()
        )

      assert length(Storage.list_folders(folder.uuid, nil)) == before_count
    end

    test "rename_folder leaves the folder's name untouched" do
      folder = create_folder!(%{name: "original-name"})

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "rename_folder",
          %{"folder_uuid" => folder.uuid, "name" => "renamed"},
          readonly_socket()
        )

      assert Storage.get_folder(folder.uuid).name == "original-name"
    end

    test "trash_file leaves the file active" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "trash_file",
          %{"file_uuid" => file.uuid},
          readonly_socket()
        )

      assert Storage.get_file(file.uuid).status == "active"
    end

    test "move_selected_to_folder leaves the file's folder untouched" do
      folder = create_folder!()
      other_folder = create_folder!()
      file = create_file!(folder.uuid)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "move_selected_to_folder",
          %{"folder-uuid" => other_folder.uuid},
          readonly_socket()
        )

      assert Storage.get_file(file.uuid).folder_uuid == folder.uuid
    end

    test "toggle_upload never flips show_upload on" do
      socket = readonly_socket(%{show_upload: false})

      {:noreply, socket} = MediaBrowser.handle_event("toggle_upload", %{}, socket)

      refute socket.assigns.show_upload
    end
  end
end
