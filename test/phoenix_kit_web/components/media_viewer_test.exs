defmodule PhoenixKitWeb.Components.MediaViewerTest do
  @moduledoc """
  Unit tests for PhoenixKitWeb.Components.MediaViewer.
  Render tests use pre-built assigns and `rendered_to_string/1`; event tests
  invoke `handle_event/3` against a minimal socket. No DB required.
  """
  use ExUnit.Case, async: true

  # `render_component` macro reads @endpoint at compile time.
  # The endpoint is started once in test_helper.exs (no DB required).
  @endpoint PhoenixKitWeb.Endpoint

  import Phoenix.LiveViewTest, except: [render: 1]

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

  describe "single-root constraint (stateful component)" do
    # Phoenix LiveView raises ArgumentError at runtime when rendered.root != true
    # for stateful components with an id. This constraint is NOT caught by
    # rendered_to_string/1 — only by inspecting the Rendered struct directly.
    # Regression for: templates with <% %> expressions or text before root tag.
    test "rendered struct satisfies LiveView single-root requirement" do
      rendered = MediaViewer.render(viewer_assigns([]))

      assert rendered.root == true,
             "MediaViewer template violates single-root constraint (rendered.root=#{inspect(rendered.root)}). " <>
               "Ensure no <% %> expressions or other content appear before the root <dialog>."
    end

    # render_component/2 exercises the real Diff.component_to_rendered path and
    # raises ArgumentError if rendered.root != true for a component with an id.
    # No DB needed: variants_map and file_structs are passed directly.
    test "render_component mounts as stateful LiveComponent without raising" do
      html =
        render_component(MediaViewer,
          id: "viewer-root-check",
          files: [@u1],
          current: @u1,
          variants_map: %{@u1 => []},
          file_structs: []
        )

      assert html =~ ~s(<dialog)
      assert html =~ "modal"
    end
  end

  describe "render" do
    test "renders the modal with the current image" do
      html = render(viewer_assigns(current: @u1))
      assert html =~ ~s(<dialog)
      assert html =~ "modal"
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

  describe "download link" do
    test "renders download link when original variant is present" do
      html =
        render(
          viewer_assigns(
            current: @u1,
            files: [@u1],
            variants_map: %{
              @u1 => [
                %{
                  variant_name: "original",
                  mime_type: "image/jpeg",
                  width: 800,
                  height: 600,
                  url: "https://example.com/file.jpg"
                }
              ]
            }
          )
        )

      assert html =~ "https://example.com/file.jpg"
      assert html =~ "Download"
    end
  end

  describe "close" do
    test "close_viewer sends {MediaViewer, id, :closed} to self when notify is nil" do
      assigns = viewer_assigns(notify: nil)
      socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
      MediaViewer.handle_event("close_viewer", %{}, socket)
      assert_received {PhoenixKitWeb.Components.MediaViewer, "test-viewer", :closed}
    end

    test "viewer_keydown Escape sends closed message when notify is nil" do
      assigns = viewer_assigns(notify: nil)
      socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
      MediaViewer.handle_event("viewer_keydown", %{"key" => "Escape"}, socket)
      assert_received {PhoenixKitWeb.Components.MediaViewer, "test-viewer", :closed}
    end

    test "viewer_keydown unknown key is a no-op (no close)" do
      assigns = viewer_assigns(notify: nil)
      {:noreply, socket} = call("viewer_keydown", %{"key" => "Tab"}, assigns)
      assert socket.assigns.current_uuid == @u1
      refute_received {PhoenixKitWeb.Components.MediaViewer, _, _}
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
