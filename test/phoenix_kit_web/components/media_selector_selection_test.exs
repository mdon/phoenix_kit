defmodule PhoenixKitWeb.Live.Components.MediaSelectorSelectionTest do
  @moduledoc """
  The media selector hands its host whatever was picked, and hosts point
  records at it (an avatar, a featured image). A file uuid the browser
  sends is taken only when the picker could have listed that file: inside
  its scope folder, of its locked type, live.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         test_pid: session["test_pid"],
         scope: session["scope"],
         mode: String.to_existing_atom(session["mode"] || "single"),
         lock: session["lock"] || false,
         browse: Map.get(session, "browse", true)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaSelectorModal}
        id="picker"
        show={true}
        mode={@mode}
        selected_uuids={[]}
        scope_folder_id={@scope}
        file_type_filter={:image}
        lock_file_type={@lock}
        browse={@browse}
        phoenix_kit_current_user={nil}
      />
      """
    end

    def handle_info({:media_selected, uuids}, socket) do
      send(socket.assigns.test_pid, {:picked, uuids})
      {:noreply, socket}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end

  defp file!(folder, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %StorageFile{
          original_file_name: "f#{n}.png",
          file_name: "f#{n}.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "ms-#{n}",
          user_file_checksum: "ms-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder && folder.uuid,
          user_uuid: Process.get(:owner_uuid)
        },
        attrs
      )
    )
  end

  defp open(conn, scope, opts \\ []) do
    live_isolated(conn, Host,
      session: %{
        "test_pid" => self(),
        "scope" => scope && scope.uuid,
        "mode" => to_string(Keyword.get(opts, :mode, :single)),
        "lock" => Keyword.get(opts, :lock, false),
        "browse" => Keyword.get(opts, :browse, true)
      }
    )
  end

  # A forged pick: a listed tile's event carrying another file's uuid — what
  # a crafted websocket frame does — then Confirm, if anything got selected.
  defp forge(view, listed, uuid) do
    view
    |> element(~s(div[phx-value-file-uuid="#{listed.uuid}"]))
    |> render_click(%{"file-uuid" => uuid})

    unless has_element?(view, ~s(button[phx-click="confirm_selection"][disabled])),
      do: confirm(view)
  end

  defp forge_double_click(view, uuid) do
    view
    |> with_target("#media-selector-modal-backdrop-picker")
    |> render_hook("quick_confirm", %{"file-uuid" => uuid})
  end

  defp confirm(view),
    do: view |> element(~s(button[phx-click="confirm_selection"])) |> render_click()

  setup do
    {user, _token} = create_admin_user()
    Process.put(:owner_uuid, user.uuid)
    {:ok, scope} = Storage.create_folder(%{name: "Scope #{System.unique_integer([:positive])}"})
    {:ok, other} = Storage.create_folder(%{name: "Other #{System.unique_integer([:positive])}"})
    %{scope: scope, other: other}
  end

  test "a file the picker lists is picked", %{conn: conn, scope: scope} do
    inside = file!(scope)
    {:ok, view, _html} = open(conn, scope)

    view |> element(~s(div[phx-value-file-uuid="#{inside.uuid}"])) |> render_click()
    confirm(view)
    assert_receive {:picked, [picked]}
    assert picked == inside.uuid
  end

  test "a forged uuid outside the scope folder is refused", %{
    conn: conn,
    scope: scope,
    other: other
  } do
    inside = file!(scope)
    outside = file!(other)
    {:ok, view, _html} = open(conn, scope)

    forge(view, inside, outside.uuid)
    refute_receive {:picked, _}, 100
  end

  test "a forged double-click on a file outside the scope is refused", %{
    conn: conn,
    scope: scope,
    other: other
  } do
    inside = file!(scope)
    outside = file!(other)
    {:ok, view, _html} = open(conn, scope)

    forge_double_click(view, outside.uuid)
    refute_receive {:picked, _}, 100

    forge_double_click(view, inside.uuid)
    assert_receive {:picked, [picked]}
    assert picked == inside.uuid
  end

  test "a trashed file, or one of another type when the type is locked, is refused", %{
    conn: conn,
    scope: scope
  } do
    inside = file!(scope)
    trashed = file!(scope, %{status: "trashed"})
    video = file!(scope, %{file_type: "video", mime_type: "video/mp4"})
    {:ok, view, _html} = open(conn, scope, lock: true)

    forge(view, inside, trashed.uuid)
    refute_receive {:picked, _}, 100
    forge(view, inside, video.uuid)
    refute_receive {:picked, _}, 100
  end

  test "an upload-only picker lists nothing, so it picks nothing it was sent", %{
    conn: conn,
    scope: scope
  } do
    inside = file!(scope)
    {:ok, view, _html} = open(conn, scope, browse: false)

    view
    |> with_target("#media-selector-modal-backdrop-picker")
    |> render_hook("toggle_selection", %{"file-uuid" => inside.uuid})

    # Nothing was selected, so there is nothing to confirm.
    assert has_element?(view, ~s(button[phx-click="confirm_selection"][disabled]))

    forge_double_click(view, inside.uuid)
    refute_receive {:picked, _}, 100
  end
end
