defmodule PhoenixKitWeb.Components.MediaBrowserViewerUrlTest do
  @moduledoc """
  The modal viewer's file rides the URL (`?file=<uuid>`) next to the
  folder, so a refresh lands back in the viewer on that file — not at
  root with the modal gone and the user hunting for the folder and file
  again. Three parts: the Embed helpers parse/build the param, the
  component's nav path syncs the viewer from it (fast-pathing when only
  the file changed, so opening a viewer never reloads the listing), and
  viewer events announce themselves so the URL follows.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaBrowser.Embed

  # ── Embed: the URL half ──────────────────────────────────────────────

  test "file survives the parse → build round trip" do
    params = %{"folder" => "f-1", "file" => "img-9"}
    nav = Embed.parse_nav_params(params)
    assert nav.file == "img-9"
    assert Embed.build_nav_query(nav) == %{"folder" => "f-1", "file" => "img-9"}
  end

  test "no viewer, no param — a closed viewer keeps the URL clean" do
    nav = Embed.parse_nav_params(%{"folder" => "f-1"})
    assert nav.file == nil
    refute Map.has_key?(Embed.build_nav_query(nav), "file")
  end

  # ── The component: nav params drive the viewer ───────────────────────

  @file_a %{file_uuid: "img-a", filename: "a.png"}
  @file_b %{file_uuid: "img-b", filename: "b.png"}

  # A socket whose listing already matches the nav params (root, page 1,
  # no search) — apply_nav_params takes its fast path and touches no
  # storage, which is also the assertion that opening a viewer does not
  # reload the listing.
  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            uploaded_files: [@file_a, @file_b],
            stack_files: %{},
            current_folder: nil,
            search_query: "",
            current_page: 1,
            filter_orphaned: false,
            file_view: nil,
            viewer_file: nil,
            viewer_siblings: [],
            upload_in_flight: false,
            show_upload: false
          },
          assigns
        )
    }
  end

  defp nav(file),
    do: %{folder: nil, q: "", page: 1, filter_orphaned: false, view: nil, file: file}

  test "?file= opens the viewer on that file, siblings from the listing" do
    {:ok, socket} = MediaBrowser.update(%{nav_params: nav("img-b")}, socket_with(%{}))
    assert socket.assigns.viewer_file.file_uuid == "img-b"
    assert socket.assigns.viewer_siblings == [@file_a, @file_b], "prev/next step the page"
  end

  test "no file in the URL closes an open viewer — Back closes what it opened" do
    {:ok, socket} =
      MediaBrowser.update(
        %{nav_params: nav(nil)},
        socket_with(%{viewer_file: @file_a, viewer_siblings: [@file_a]})
      )

    assert socket.assigns.viewer_file == nil
    assert socket.assigns.viewer_siblings == []
  end

  test "the already-open file is left alone — the feed-back after an open is a no-op" do
    original_siblings = [@file_a]

    {:ok, socket} =
      MediaBrowser.update(
        %{nav_params: nav("img-a")},
        socket_with(%{viewer_file: @file_a, viewer_siblings: original_siblings})
      )

    assert socket.assigns.viewer_file == @file_a

    assert socket.assigns.viewer_siblings == original_siblings,
           "re-locating would rebind the step list mid-session"
  end

  # ── Viewer events announce the file so the URL follows ───────────────

  defp controlled(assigns),
    do: socket_with(Map.merge(%{id: "mb", on_navigate: :navigate, select_mode: false}, assigns))

  test "opening a file announces it" do
    {:noreply, _} =
      MediaBrowser.handle_event("click_file", %{"file-uuid" => "img-b"}, controlled(%{}))

    assert_received {MediaBrowser, "mb", {:navigate, %{file: "img-b", folder: nil}}}
  end

  test "closing announces the file's absence" do
    {:noreply, _} =
      MediaBrowser.handle_event(
        "close_viewer",
        %{},
        controlled(%{viewer_file: @file_a, viewer_siblings: [@file_a]})
      )

    assert_received {MediaBrowser, "mb", {:navigate, %{file: nil}}}
  end

  test "stepping announces the neighbour" do
    {:noreply, _} =
      MediaBrowser.handle_event(
        "step_viewer",
        %{"dir" => "next"},
        controlled(%{viewer_file: @file_a, viewer_siblings: [@file_a, @file_b]})
      )

    assert_received {MediaBrowser, "mb", {:navigate, %{file: "img-b"}}}
  end

  test "an uncontrolled host hears nothing — local state only, as before" do
    {:noreply, _} =
      MediaBrowser.handle_event(
        "click_file",
        %{"file-uuid" => "img-a"},
        socket_with(%{id: "mb", on_navigate: nil, select_mode: false})
      )

    refute_received {MediaBrowser, _, {:navigate, _}}
  end
end
