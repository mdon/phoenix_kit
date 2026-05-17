defmodule PhoenixKitWeb.Components.MediaViewerTest do
  @moduledoc """
  Unit tests for PhoenixKitWeb.Components.MediaViewer.
  Render tests use pre-built assigns and `rendered_to_string/1`; event tests
  invoke `handle_event/3` against a minimal socket. No DB required.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.MediaViewer

  @u1 "01900000-0000-7000-8000-000000000001"
  @u2 "01900000-0000-7000-8000-000000000002"
  @u3 "01900000-0000-7000-8000-000000000003"

  defp viewer_assigns(opts) do
    files = Keyword.get(opts, :files, [@u1, @u2, @u3])
    current = Keyword.get(opts, :current, @u1)

    %{
      id: "test-viewer",
      current_uuid: current,
      files: files,
      variants_map: Keyword.get(opts, :variants_map, Map.new(files, &{&1, []})),
      file_structs: Keyword.get(opts, :file_structs, []),
      notify: Keyword.get(opts, :notify, nil),
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  defp render(assigns), do: rendered_to_string(MediaViewer.render(assigns))

  defp call(event, params, assigns) do
    socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
    MediaViewer.handle_event(event, params, socket)
  end

  describe "render" do
    test "renders the modal with the current image" do
      html = render(viewer_assigns(current: @u1))
      assert html =~ "modal modal-open"
      assert html =~ "test-viewer"
    end

    test "shows next chevron but not prev on the first image" do
      html = render(viewer_assigns(current: @u1))
      assert html =~ ~s(phx-value-dir="next")
      refute html =~ ~s(phx-value-dir="prev")
    end

    test "shows prev chevron but not next on the last image" do
      html = render(viewer_assigns(current: @u3))
      assert html =~ ~s(phx-value-dir="prev")
      refute html =~ ~s(phx-value-dir="next")
    end
  end

  describe "stepping" do
    test "step_viewer next advances current_uuid" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "next"}, viewer_assigns(current: @u1))
      assert socket.assigns.current_uuid == @u2
    end

    test "step_viewer prev goes back" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "prev"}, viewer_assigns(current: @u2))
      assert socket.assigns.current_uuid == @u1
    end

    test "step_viewer next at the last image is a no-op" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "next"}, viewer_assigns(current: @u3))
      assert socket.assigns.current_uuid == @u3
    end

    test "ArrowRight steps forward, ArrowLeft steps back" do
      {:noreply, s1} =
        call("viewer_keydown", %{"key" => "ArrowRight"}, viewer_assigns(current: @u1))

      assert s1.assigns.current_uuid == @u2

      {:noreply, s2} =
        call("viewer_keydown", %{"key" => "ArrowLeft"}, viewer_assigns(current: @u2))

      assert s2.assigns.current_uuid == @u1
    end
  end
end
