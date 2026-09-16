defmodule PhoenixKitWeb.Components.MediaBrowserUploadDrawerTest do
  @moduledoc """
  The upload drawer closes itself the moment files are accepted:
  transfers are auto_upload and render as the inline progress rows the
  drag-drop path uses, so an open drawer past that point only spends
  vertical space. The close fires on the idle→uploading TRANSITION of
  the parent's upload entries, never on their mere presence — a user
  who reopens the drawer mid-upload to add more files must not fight a
  panel that snaps shut on every progress tick.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaBrowser

  # A socket already past first mount (uploaded_files present), so
  # update/2 takes its plain assign path and touches no storage.
  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            uploaded_files: [],
            show_upload: true,
            upload_in_flight: false
          },
          assigns
        )
    }
  end

  defp uploads(entries), do: %{media_files: %{entries: entries}}

  test "the drawer closes when in-flight entries first appear" do
    {:ok, socket} =
      MediaBrowser.update(%{parent_uploads: uploads([%{ref: "0"}])}, socket_with(%{}))

    refute socket.assigns.show_upload, "accepted files end the drawer's job"
    assert socket.assigns.upload_in_flight
  end

  test "reopening the drawer mid-upload sticks — no close without a fresh start" do
    # Entries were already in flight when this render arrived (the user
    # reopened the drawer while a transfer ran).
    {:ok, socket} =
      MediaBrowser.update(
        %{parent_uploads: uploads([%{ref: "0"}])},
        socket_with(%{upload_in_flight: true})
      )

    assert socket.assigns.show_upload,
           "presence of entries is not the trigger — only their first appearance is"
  end

  test "an idle render leaves the drawer alone and re-arms the trigger" do
    {:ok, socket} =
      MediaBrowser.update(
        %{parent_uploads: uploads([])},
        socket_with(%{upload_in_flight: true})
      )

    assert socket.assigns.show_upload
    refute socket.assigns.upload_in_flight, "the batch ended — the next pick may close again"
  end

  test "a start with the drawer already closed changes nothing visible" do
    {:ok, socket} =
      MediaBrowser.update(
        %{parent_uploads: uploads([%{ref: "0"}])},
        socket_with(%{show_upload: false})
      )

    refute socket.assigns.show_upload
    assert socket.assigns.upload_in_flight, "…but the transition is still consumed"
  end
end
