defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaTest do
  @moduledoc """
  The viewer sidebar's "Title & description" section: the file's own
  words about itself, collapsible behind a chevron, editable in the
  contexts that can already reach the metadata editor (details_path /
  edit_target hosts). Writes go into the file's metadata JSONB under
  the same keys the admin detail page's editor uses — merged, never
  replacing, so rotation/tags survive a title edit.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  # `details_path` stands in for the host opt-in that makes the section an
  # editor at all — without one (or an `edit_target`) the save handler
  # refuses, see the "an unentitled host" test.
  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            media_details_open: false,
            details_path: "/admin/media/x",
            edit_target: nil,
            media_meta_status_token: 0
          },
          assigns
        )
    }
  end

  # A real row: `user_uuid` and both checksums are required, so a bare
  # name/mime map never inserts.
  defp file!(name, metadata) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "media-meta-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      %Storage.File{}
      |> Storage.File.changeset(%{
        original_file_name: "#{name}.png",
        file_name: "#{name}.png",
        file_path: "aa/bb/#{name}",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        size: 10,
        status: "active",
        user_uuid: user.uuid,
        file_checksum: "checksum-#{n}",
        user_file_checksum: "user-checksum-#{n}",
        metadata: metadata
      })
      |> Repo.insert()

    file
  end

  describe "saving (DB)" do
    setup do
      # The keys a title edit must NOT disturb.
      %{row: file!("meta_test", %{"rotation" => 90, "tags" => ["a", "b"]})}
    end

    test "merges title and description into the row's metadata", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "  A title  ", "description" => "Words."},
          socket
        )

      assert socket.assigns.media_meta == %{title: "A title", description: "Words."}
      assert socket.assigns.media_meta_status == :saved

      row = Storage.get_file(file.uuid)
      assert row.metadata["title"] == "A title"
      assert row.metadata["description"] == "Words."
      assert row.metadata["rotation"] == 90, "a title edit must never eat the rotation"
      assert row.metadata["tags"] == ["a", "b"], "…or the tags"
    end

    test "a vanished row reports an error instead of raising", %{row: file} do
      Repo.delete!(file)

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "x"}, socket)

      assert socket.assigns.media_meta_status == :error
    end

    # The section renders read-only for hosts that offer no road to the
    # metadata editor — a readonly MediaGallery lightbox, which may be
    # showing an anonymous visitor. The form is absent there, so the only
    # way this event arrives is a hand-rolled push: the server, not the
    # template, has to say no.
    test "an unentitled host cannot write the row", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil,
          details_path: nil,
          edit_target: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "Injected", "description" => "Injected"},
          socket
        )

      assert socket.assigns.media_meta_status == nil, "a refusal is silent, not an error pill"
      assert socket.assigns.media_meta == %{title: "", description: ""}

      row = Storage.get_file(file.uuid)
      refute Map.has_key?(row.metadata, "title")
      assert row.metadata["rotation"] == 90
    end

    test "an edit_target host may write" do
      file = file!("meta_edit_target", %{})

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil,
          details_path: nil,
          edit_target: {MediaCanvasViewer, "host-1"}
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "Ok"}, socket)

      assert socket.assigns.media_meta_status == :saved
      assert Storage.get_file(file.uuid).metadata["title"] == "Ok"
    end
  end
end

defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaUnitTest do
  @moduledoc "The DB-less half: the chevron toggle and the status clear."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{__changed__: %{}, media_details_open: false, media_meta_status_token: 0},
          assigns
        )
    }
  end

  test "the chevron toggles the section" do
    {:noreply, socket} =
      MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket_with(%{}))

    assert socket.assigns.media_details_open

    {:noreply, socket} = MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket)
    refute socket.assigns.media_details_open
  end

  test "the transient save status clears" do
    {:ok, socket} =
      MediaCanvasViewer.update(
        %{action: :clear_media_meta_status, token: 3},
        socket_with(%{media_meta_status: :saved, media_meta_status_token: 3})
      )

    assert socket.assigns.media_meta_status == nil
  end

  # A second Save inside the two-second window bumps the token, so the
  # first save's timer must not wipe the status the second one just put up.
  test "a stale auto-hide timer leaves a newer status alone" do
    {:ok, socket} =
      MediaCanvasViewer.update(
        %{action: :clear_media_meta_status, token: 3},
        socket_with(%{media_meta_status: :saved, media_meta_status_token: 4})
      )

    assert socket.assigns.media_meta_status == :saved
  end
end
