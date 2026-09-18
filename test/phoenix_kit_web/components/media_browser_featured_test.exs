defmodule PhoenixKitWeb.Components.MediaBrowserFeaturedTest do
  @moduledoc """
  The `:featured` attr (nil = off) turns on a host-owned featured-image
  UI: a "Set as featured" / "Unset featured" kebab item on every image
  tile (grid, list, stack) and its viewer-sidebar counterpart, plus a
  star badge on the current pointer. The component never persists
  anything — it only relays the uuid to the host via
  `{MediaBrowser, id, {:set_featured, uuid | nil}}` and optimistically
  flips its own badge/kebab state ahead of the host's write.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  # ---------------------------------------------------------------------------
  # Helpers (same fixtures other MediaBrowser tests use)
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

  defp create_trashed_file!(folder_uuid) do
    file = create_file!(folder_uuid)

    {:ok, file} =
      file
      |> Ecto.Changeset.change(%{
        status: "trashed",
        trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()

    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "media-browser-featured-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  # ---------------------------------------------------------------------------
  # (a)/(b) Render — grid view
  # ---------------------------------------------------------------------------

  describe "render — featured off" do
    test "no star badge and no kebab item render for any file" do
      folder = create_folder!()
      _file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          featured: nil
        )

      refute html =~ ~s(data-role="featured-badge")
      refute html =~ "set_featured"
      refute html =~ "unset_featured"
      refute html =~ "Set as featured"
    end
  end

  describe "render — featured set" do
    test "the matching tile carries the badge and offers Unset, others offer Set" do
      folder = create_folder!()
      featured_file = create_file!(folder.uuid)
      other_file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          featured: %{uuid: featured_file.uuid, label: nil}
        )

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, ~s([data-role="featured-badge"]))),
             "expected a featured-badge overlay somewhere in the grid"

      refute Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-click="unset_featured"][phx-value-file-uuid="#{featured_file.uuid}"])
               )
             ),
             "the currently-featured tile's kebab should offer Unset"

      refute Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-click="set_featured"][phx-value-file-uuid="#{other_file.uuid}"])
               )
             ),
             "every other image tile's kebab should offer Set"

      assert Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-click="set_featured"][phx-value-file-uuid="#{featured_file.uuid}"])
               )
             ),
             "the featured tile itself should not also offer Set"
    end

    test "the badge's title tooltip sits on a pointer-events-auto inner element, not the pointer-events-none outer badge" do
      folder = create_folder!()
      featured_file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          featured: %{uuid: featured_file.uuid, label: "Cover shot"}
        )

      doc = LazyHTML.from_fragment(html)
      badge = LazyHTML.query(doc, ~s([data-role="featured-badge"]))

      # The outer badge stays pointer-events-none (so it doesn't block clicks
      # on the tile underneath) and therefore must not carry the title itself
      # — a div that never receives pointer events never shows its tooltip.
      refute LazyHTML.attribute(badge, "class") |> hd() =~ "pointer-events-auto"
      assert LazyHTML.attribute(badge, "title") == []

      # The title lives on an inner element that opts back into pointer
      # events, sized to the badge, so hovering the star actually triggers it.
      tooltip_el = LazyHTML.query(doc, ~s([data-role="featured-badge"] [title]))
      assert LazyHTML.attribute(tooltip_el, "title") == ["Cover shot"]
      assert LazyHTML.attribute(tooltip_el, "class") |> hd() =~ "pointer-events-auto"
    end

    test "a non-image file gets neither the badge nor the kebab item" do
      folder = create_folder!()
      n = System.unique_integer([:positive])

      {:ok, pdf_file} =
        Repo.insert(%StorageFile{
          original_file_name: "doc_#{n}.pdf",
          file_name: "doc_#{n}.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "sha256:test-#{n}",
          user_file_checksum: "user-sha256:test-#{n}",
          size: 2048,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: ensure_user!()
        })

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          featured: %{uuid: pdf_file.uuid, label: nil}
        )

      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, ~s([data-role="featured-badge"])))

      assert Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-value-file-uuid="#{pdf_file.uuid}"][phx-click="set_featured"])
               )
             )

      assert Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-value-file-uuid="#{pdf_file.uuid}"][phx-click="unset_featured"])
               )
             )
    end
  end

  # ---------------------------------------------------------------------------
  # (c)/(d) Events — direct handle_event/3 calls against a plain socket, the
  # style `media_browser_viewer_url_test.exs` uses.
  # ---------------------------------------------------------------------------

  defp socket_with(featured) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, id: "mb", featured: featured}}
  end

  describe "set_featured / unset_featured events" do
    test "set_featured sends the tuple to the host and flips the badge locally" do
      {:noreply, socket} =
        MediaBrowser.handle_event(
          "set_featured",
          %{"file-uuid" => "img-a"},
          socket_with(%{uuid: nil, label: nil})
        )

      assert_received {MediaBrowser, "mb", {:set_featured, "img-a"}}
      assert socket.assigns.featured.uuid == "img-a"
    end

    test "unset_featured sends {:set_featured, nil} and clears the local uuid" do
      {:noreply, socket} =
        MediaBrowser.handle_event(
          "unset_featured",
          %{},
          socket_with(%{uuid: "img-a", label: nil})
        )

      assert_received {MediaBrowser, "mb", {:set_featured, nil}}
      assert socket.assigns.featured.uuid == nil
    end

    test "both are a no-op when the host never opted in (featured: nil)" do
      {:noreply, set_socket} =
        MediaBrowser.handle_event("set_featured", %{"file-uuid" => "img-a"}, socket_with(nil))

      refute_received {MediaBrowser, _, _}
      assert set_socket.assigns.featured == nil

      {:noreply, unset_socket} =
        MediaBrowser.handle_event("unset_featured", %{}, socket_with(nil))

      refute_received {MediaBrowser, _, _}
      assert unset_socket.assigns.featured == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Viewer sidebar toggle — end to end through a tiny host LiveView, the way
  # `PhoenixKitWeb.Components.ImageEditorTest` drives MediaCanvasViewer's
  # sidebar buttons via `live_isolated/3`.
  # ---------------------------------------------------------------------------

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.MediaBrowser

    # ConnCase's `using` block (in scope from the enclosing test module)
    # imports `Plug.Conn`, which also exports `assign/3` and makes a bare
    # `assign/3` call ambiguous — go through `Phoenix.Component` directly.
    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> MediaBrowser.setup_uploads()
       |> set_assign(:folder_uuid, session["folder_uuid"])
       |> set_assign(:featured, session["featured"])
       |> set_assign(:test_pid, session["test_pid"])}
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    # Must be matched before the generic delegator below — see
    # MediaBrowser's moduledoc note on `:featured`.
    def handle_info({MediaBrowser, _id, {:set_featured, uuid}}, socket) do
      send(socket.assigns.test_pid, {:set_featured_received, uuid})
      {:noreply, set_assign(socket, :featured, %{socket.assigns.featured | uuid: uuid})}
    end

    def handle_info({MediaBrowser, _, _} = msg, socket) do
      MediaBrowser.handle_parent_info(msg, socket)
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="mb"
        scope_folder_id={@folder_uuid}
        featured={@featured}
      />
      """
    end
  end

  defp open_host(folder, featured) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{
          "folder_uuid" => folder.uuid,
          "featured" => featured,
          "test_pid" => self()
        }
      )

    view
  end

  describe "viewer sidebar toggle" do
    test "clicking the sidebar button in the open viewer notifies the host" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, %{uuid: nil, label: nil})

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      html =
        view
        |> element(
          "#mb-viewer-modal [phx-click='set_featured'][phx-value-file-uuid='#{file.uuid}']"
        )
        |> render_click()

      assert_receive {:set_featured_received, file_uuid} when file_uuid == file.uuid
      assert html =~ "Unset featured"
    end

    test "a trashed image offers no toggle, matching the kebabs' !@filter_trash gate" do
      # The three kebabs hide the action while the trash listing is up, but the
      # viewer opens on trashed files too (a trash tile clicks straight through
      # to it) — without its own gate the sidebar would happily make a file on
      # its way out the host's featured image.
      folder = create_folder!()
      file = create_trashed_file!(folder.uuid)
      view = open_host(folder, %{uuid: nil, label: nil})

      view |> element("[phx-click='toggle_trash_filter']") |> render_click()

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")
      refute has_element?(view, "#mb-viewer-modal [phx-click='set_featured']")
    end

    test "the toggle is not offered when the host never opted in" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, nil)

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      refute has_element?(view, "[phx-click='set_featured']")
      refute html =~ "Set as featured"
    end
  end
end
