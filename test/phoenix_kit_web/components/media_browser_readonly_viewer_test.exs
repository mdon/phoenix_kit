defmodule PhoenixKitWeb.Components.MediaBrowserReadonlyViewerTest do
  @moduledoc """
  Issue #840's `readonly` attr has to close three holes one level down, in
  the `MediaCanvasViewer` child the modal viewer embeds: `can_annotate`
  (Etcher shapes), `edit_target` AND `details_path` (title/alt/description
  save — MediaCanvasViewer's `save_media_details` clause only refuses the
  write when BOTH are nil, so `readonly` nils both, even with `admin: true`
  where `details_path` would otherwise stay truthy), and `persist_rotation`.

  The Edit-image button and the meta-edit form are this component's own
  markup, so they're asserted end to end through a real host LiveView.
  `can_annotate`, `persist_rotation`, and (belt-and-braces, alongside the
  end-to-end markup check) `save_media_details` are asserted with direct
  `MediaCanvasViewer.handle_event/3` calls using the exact assigns a
  readonly `MediaBrowser` hands the child — Etcher's and Fresco's own
  rendered markup belong to those packages, not to this component.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaCanvasViewer

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
            email: "media-browser-readonly-viewer-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  # ---------------------------------------------------------------------------
  # edit_target — end to end through a real host, admin: true so
  # `details_path` is also truthy (proving that alone is not the boundary).
  # ---------------------------------------------------------------------------

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.MediaBrowser

    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> MediaBrowser.setup_uploads()
       |> set_assign(:folder_uuid, session["folder_uuid"])
       |> set_assign(:readonly, session["readonly"])
       |> set_assign(:admin, session["admin"])}
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    def handle_info({MediaBrowser, _, _} = msg, socket) do
      MediaBrowser.handle_parent_info(msg, socket)
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="mb"
        scope_folder_id={@folder_uuid}
        readonly={@readonly}
        admin={@admin}
      />
      """
    end
  end

  defp open_host(folder, readonly, admin) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"folder_uuid" => folder.uuid, "readonly" => readonly, "admin" => admin}
      )

    view
  end

  describe "MediaCanvasViewer's edit_target and details_path under readonly" do
    test "Edit image is absent even with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, true, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")
      refute has_element?(view, "[phx-click='edit_image']")
    end

    test "regression: Edit image is still offered in normal mode with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, false, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "[phx-click='edit_image']")
    end

    test "the meta-edit form (title/alt/description save) is absent even with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, true, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")
      refute has_element?(view, "#media-meta-form-#{file.uuid}")
    end

    test "belt-and-braces: save_media_details no-ops once both details_path and edit_target are nil" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      # The exact assign shape the readonly + admin: true `.live_component`
      # call now produces (see media_browser.html.heex) — both nil, closing
      # the gap where `details_path` alone used to be enough.
      socket =
        viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{
          details_path: nil,
          edit_target: nil
        })

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "hacked"},
          socket
        )

      reloaded = Storage.get_file(file.uuid)
      title = FileDetails.from_file(reloaded).title

      refute title == "hacked"
      assert title in [nil, ""]
    end
  end

  # ---------------------------------------------------------------------------
  # can_annotate / persist_rotation — direct handle_event/3 calls against the
  # exact assign shape the readonly-wired `.live_component` call produces.
  # ---------------------------------------------------------------------------

  defp viewer_socket(file, overrides) do
    base = %{
      __changed__: %{},
      id: "canvas-test",
      file: file,
      board: nil,
      can_annotate: false,
      edit_target: nil,
      persist_rotation: false,
      details_path: nil,
      write_scope: nil
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, overrides)}
  end

  describe "MediaCanvasViewer honors can_annotate: false" do
    test "etcher:annotations-changed is refused outright — the socket comes back unchanged" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      socket = viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{})

      assert {:noreply, ^socket} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [%{"uuid" => "shape-1", "kind" => "rectangle"}]},
                 socket
               )
    end
  end

  describe "MediaCanvasViewer honors persist_rotation: false" do
    test "fresco:rotate does not persist" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      socket = viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{})

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event("fresco:rotate", %{"rotation" => 90}, socket)

      reloaded = Storage.get_file(file.uuid)
      refute Map.get(reloaded.metadata || %{}, "rotation")
    end

    test "regression: fresco:rotate persists when persist_rotation is true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      socket =
        viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{
          persist_rotation: true
        })

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event("fresco:rotate", %{"rotation" => 90}, socket)

      reloaded = Storage.get_file(file.uuid)
      assert Map.get(reloaded.metadata || %{}, "rotation") == 90
    end
  end
end
