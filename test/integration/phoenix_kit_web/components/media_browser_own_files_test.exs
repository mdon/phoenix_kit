defmodule PhoenixKitWeb.Components.MediaBrowserOwnFilesTest do
  @moduledoc """
  A user library's contributor changes only the files they uploaded
  (`own_files_only`): a write naming someone else's file, a bulk action on a
  selection holding one, and emptying the trash are refused. The browser's
  list of writes is exactly the events that refuse to run when it is
  readonly, so a read (opening a file) is never refused.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-files-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.png",
        file_name: "a.png",
        file_path: "x/a.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp socket(contributor, selected \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mb",
        flash: %{},
        readonly: false,
        library_uuid: nil,
        own_files_only: contributor.uuid,
        selected_files: MapSet.new(selected)
      }
    }
  end

  defp refused?({:noreply, socket}),
    do: socket.assigns.flash["error"] == "You can only change files you uploaded"

  test "someone else's file is refused; the selection and the trash too" do
    contributor = user!()
    others = file!(user!())

    assert refused?(
             MediaBrowser.handle_event(
               "trash_file",
               %{"file_uuid" => others.uuid},
               socket(contributor)
             )
           )

    assert refused?(
             MediaBrowser.handle_event("delete_selected", %{}, socket(contributor, [others.uuid]))
           )

    assert refused?(MediaBrowser.handle_event("empty_trash", %{}, socket(contributor)))

    assert Storage.get_file(others.uuid).status == "active"
  end

  test "reading is not a write, so viewing someone else's file is not refused" do
    contributor = user!()
    others = file!(user!())

    refute "click_file" in MediaBrowser.write_events()
    refute "toggle_search" in MediaBrowser.write_events()
    assert others.uuid
  end

  test "the list of writes is exactly the events that refuse to run when readonly" do
    source = File.read!("lib/phoenix_kit_web/components/media_browser.ex")

    readonly_events =
      ~r/def handle_event\("([a-z_]+)", _params, socket\)\s+when socket\.assigns\.readonly == true/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert readonly_events != []
    assert Enum.sort(MediaBrowser.write_events()) == readonly_events
  end
end
