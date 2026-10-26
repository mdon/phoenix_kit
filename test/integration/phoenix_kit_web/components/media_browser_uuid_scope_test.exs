defmodule PhoenixKitWeb.Components.MediaBrowserUuidScopeTest do
  @moduledoc """
  What an event NAMES is checked against the library the browser shows and the
  viewer it shows it to: a file or folder of another library (a hidden system
  library, a second site library, a user library) or, for a restricted viewer,
  someone else's, is refused whatever the event — reading (select, download,
  open) or changing (trash, delete, move, rotate, rename, featured). The
  refusal leaves the object untouched and the selection clean.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaBrowser

  @media_path Routes.path("/admin/media")

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    n = System.unique_integer([:positive])

    {:ok, role} = Roles.create_role(%{name: "Own media #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "media")
    {:ok, _} = Permissions.grant_permission(role.uuid, "media.manage")

    alice = user!(role, "alice")
    {admin, _token} = create_admin_user()

    {:ok, hidden} =
      Libraries.create_system_library(%{name: "Hidden #{n}", slug: "hidden-#{n}"}, hidden: true)

    {:ok, other_site} = Libraries.create_system_library(%{name: "Site two #{n}"})

    {:ok, lib_role} = Roles.create_role(%{name: "Library users #{n}"})
    {:ok, _} = Permissions.grant_permission(lib_role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(lib_role.uuid, "storage.create_library")
    lib_owner = user!(lib_role, "libowner")

    {:ok, user_lib} =
      Libraries.create_user_library(Scope.for_user(lib_owner), %{"name" => "Mine #{n}"})

    # a home in Media for the legitimate actions and for move targets
    media_folder = folder!("MEDIA-#{n}", nil, admin)

    foreign =
      for {tag, lib} <- [hidden: hidden, site: other_site, user: user_lib], into: %{} do
        {tag,
         %{
           library: lib,
           folder: folder!("#{tag}-folder-#{n}", lib.uuid, admin),
           file: file!("#{tag}-file-#{n}", admin, lib.uuid)
         }}
      end

    %{
      n: n,
      admin: admin,
      alice: alice,
      foreign: foreign,
      media_folder: media_folder,
      media_file: file!("MEDIA-FILE-#{n}", admin, nil, media_folder),
      alice_file: file!("ALICE-#{n}", alice, nil),
      alice_hidden_file: file!("ALICE-HIDDEN-#{n}", alice, hidden.uuid),
      hidden: hidden
    }
  end

  defp user!(role, tag) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "uuid-scope-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp folder!(name, library_uuid, creator) when is_binary(library_uuid) or is_nil(library_uuid),
    do: do_folder!(name, nil, library_uuid, creator)

  defp folder!(name, parent, creator), do: do_folder!(name, parent.uuid, nil, creator)

  defp do_folder!(name, parent_uuid, library_uuid, creator) do
    attrs = %{name: name, parent_uuid: parent_uuid, user_uuid: creator.uuid}
    attrs = if library_uuid, do: Map.put(attrs, :library_uuid, library_uuid), else: attrs
    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp file!(name, owner, library_uuid, folder \\ nil) do
    n = System.unique_integer([:positive])

    attrs = %{
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
    }

    attrs = if library_uuid, do: Map.put(attrs, :library_uuid, library_uuid), else: attrs
    {:ok, file} = Storage.create_file(attrs)

    # an original, so that a download of it would have a URL
    Repo.insert!(%Storage.FileInstance{
      file_uuid: file.uuid,
      variant_name: "original",
      file_name: "instance_#{n}.png",
      mime_type: "image/png",
      ext: "png",
      checksum: "sha256:instance-#{n}",
      size: 1,
      width: 8,
      height: 8,
      processing_status: "completed"
    })

    file
  end

  defp browser(view), do: with_target(view, "#media-browser")

  defp bare_socket(library_uuid, viewer_uuid \\ nil, selected \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mb",
        flash: %{},
        readonly: false,
        library_uuid: library_uuid,
        viewer_uuid: viewer_uuid,
        own_files_only: nil,
        current_folder: nil,
        selected_files: MapSet.new(selected),
        selected_folders: MapSet.new()
      }
    }
  end

  defp refused?({:noreply, socket}),
    do: socket.assigns.flash["error"] == "That is not in this library"

  # ── forged events through the real page ───────────────────────────────────

  describe "from Media, an event naming an object of another library" do
    setup %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(log_in_user(conn, admin), @media_path)
      %{view: view}
    end

    test "changes no file", %{view: view, foreign: foreign} do
      for {_tag, %{file: file, folder: folder}} <- foreign do
        before = Storage.get_file(file.uuid)

        for {event, params} <- [
              {"trash_file", %{"file_uuid" => file.uuid}},
              {"delete_file", %{"file-uuid" => file.uuid}},
              {"restore_file", %{"file-uuid" => file.uuid}},
              {"rotate_file", %{"file-uuid" => file.uuid, "dir" => "right"}},
              {"set_featured", %{"file-uuid" => file.uuid}},
              {"move_file_to_folder", %{"file_uuid" => file.uuid, "folder_uuid" => folder.uuid}},
              {"click_file", %{"file-uuid" => file.uuid}},
              {"download_file", %{"file-uuid" => file.uuid}}
            ] do
          render_click(browser(view), event, params)
        end

        assert Storage.get_file(file.uuid) == before
      end
    end

    test "changes no folder", %{view: view, foreign: foreign, media_folder: media_folder} do
      for {_tag, %{folder: folder}} <- foreign do
        before = Storage.get_folder(folder.uuid)

        for {event, params} <- [
              {"trash_folder", %{"folder_uuid" => folder.uuid}},
              {"delete_folder", %{"id" => folder.uuid}},
              {"restore_folder", %{"folder-uuid" => folder.uuid}},
              {"rename_folder", %{"folder_uuid" => folder.uuid, "name" => "Hacked"}},
              {"change_folder_color", %{"folder-uuid" => folder.uuid, "color" => "red"}},
              {"move_folder_to_folder",
               %{"folder_uuid" => folder.uuid, "target_uuid" => media_folder.uuid}},
              {"navigate_folder", %{"folder_uuid" => folder.uuid}}
            ] do
          render_click(browser(view), event, params)
        end

        assert Storage.get_folder(folder.uuid) == before
      end
    end

    test "moves nothing into a folder of another library, and nothing out of Media", ctx do
      %{view: view, foreign: foreign, media_file: media_file, media_folder: media_folder} = ctx

      for {_tag, %{folder: folder}} <- foreign do
        render_click(browser(view), "move_file_to_folder", %{
          "file_uuid" => media_file.uuid,
          "folder_uuid" => folder.uuid
        })

        render_click(browser(view), "move_folder_to_folder", %{
          "folder_uuid" => media_folder.uuid,
          "target_uuid" => folder.uuid
        })

        render_click(browser(view), "move_selected_to_folder", %{"folder-uuid" => folder.uuid})
      end

      assert Storage.get_file(media_file.uuid).folder_uuid == media_folder.uuid
      assert Storage.get_folder(media_folder.uuid).parent_uuid == nil
    end

    test "a legitimate action on Media's own file still works", ctx do
      %{view: view, media_file: media_file} = ctx

      render_click(browser(view), "trash_file", %{"file_uuid" => media_file.uuid})

      assert %{status: "trashed"} = Storage.get_file(media_file.uuid)
    end
  end

  describe "as a restricted viewer, an event naming her own file of a hidden library" do
    test "is refused, and her own Media file is not", ctx do
      %{conn: conn, alice: alice, alice_hidden_file: hidden, alice_file: own} = ctx
      {:ok, view, _html} = live(log_in_user(conn, alice), @media_path)

      render_click(browser(view), "trash_file", %{"file_uuid" => hidden.uuid})
      assert %{status: "active"} = Storage.get_file(hidden.uuid)

      render_click(browser(view), "trash_file", %{"file_uuid" => own.uuid})
      assert %{status: "trashed"} = Storage.get_file(own.uuid)
    end
  end

  # ── the gate itself: selection, download, and a browser with no library ────

  describe "a browser showing one library" do
    test "keeps another library's files out of the selection", %{foreign: foreign} do
      media = Libraries.media_uuid()

      for {_tag, %{file: file, folder: folder}} <- foreign do
        for {event, params} <- [
              {"toggle_select", %{"file-uuid" => file.uuid}},
              {"long_press_select", %{"type" => "file", "uuid" => file.uuid}},
              {"toggle_select_folder", %{"folder-uuid" => folder.uuid}},
              {"prepare_move_file", %{"file-uuid" => file.uuid}},
              {"prepare_move_folder", %{"folder-uuid" => folder.uuid}}
            ] do
          result = MediaBrowser.handle_event(event, params, bare_socket(media))
          assert refused?(result)
          {:noreply, socket} = result
          assert MapSet.size(socket.assigns.selected_files) == 0
          assert MapSet.size(socket.assigns.selected_folders) == 0
        end
      end
    end

    test "an upper-case uuid is the same uuid", %{foreign: %{hidden: %{file: file}}} do
      assert refused?(
               MediaBrowser.handle_event(
                 "toggle_select",
                 %{"file-uuid" => String.upcase(file.uuid)},
                 bare_socket(Libraries.media_uuid())
               )
             )
    end

    test "a legitimate file is selected", %{media_file: media_file} do
      {:noreply, socket} =
        MediaBrowser.handle_event(
          "toggle_select",
          %{"file-uuid" => media_file.uuid},
          bare_socket(Libraries.media_uuid())
        )

      assert MapSet.member?(socket.assigns.selected_files, media_file.uuid)
    end
  end

  describe "download_selected" do
    defp pushed(socket), do: socket.private[:live_temp][:push_events] || []

    test "gives no URL for a selection that holds another library's file", ctx do
      %{foreign: foreign, media_file: media_file} = ctx
      selected = [media_file.uuid | Enum.map(foreign, fn {_t, %{file: f}} -> f.uuid end)]

      {:noreply, socket} =
        MediaBrowser.handle_event(
          "download_selected",
          %{},
          bare_socket(Libraries.media_uuid(), nil, selected)
        )

      assert [["download_files", %{files: [%{name: name}]}]] = pushed(socket)
      assert name =~ "MEDIA-FILE"
    end

    test "gives none of a viewer's selection that is not hers", %{alice: alice, media_file: mf} do
      {:noreply, socket} =
        MediaBrowser.handle_event(
          "download_selected",
          %{},
          bare_socket(Libraries.media_uuid(), alice.uuid, [mf.uuid])
        )

      assert [["download_files", %{files: []}]] = pushed(socket)
    end
  end

  describe "a browser that names no library" do
    test "refuses a hidden library's and a user library's files and folders", %{foreign: foreign} do
      for tag <- [:hidden, :user], %{file: file, folder: folder} = foreign[tag] do
        assert refused?(
                 MediaBrowser.handle_event(
                   "toggle_select",
                   %{"file-uuid" => file.uuid},
                   bare_socket(nil)
                 )
               )

        assert refused?(
                 MediaBrowser.handle_event(
                   "trash_folder",
                   %{"folder_uuid" => folder.uuid},
                   bare_socket(nil)
                 )
               )
      end
    end

    test "a site library's own are listed there, so they are not refused", ctx do
      %{foreign: %{site: %{file: file}}, media_file: media_file} = ctx

      for uuid <- [file.uuid, media_file.uuid] do
        {:noreply, socket} =
          MediaBrowser.handle_event("toggle_select", %{"file-uuid" => uuid}, bare_socket(nil))

        assert MapSet.member?(socket.assigns.selected_files, uuid)
      end
    end

    test "a viewer's own file in a hidden library is refused", %{
      alice: alice,
      alice_hidden_file: file
    } do
      assert refused?(
               MediaBrowser.handle_event(
                 "toggle_select",
                 %{"file-uuid" => file.uuid},
                 bare_socket(nil, alice.uuid)
               )
             )
    end
  end
end
