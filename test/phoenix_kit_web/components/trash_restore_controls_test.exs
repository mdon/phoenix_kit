defmodule PhoenixKitWeb.Components.TrashRestoreControlsTest do
  @moduledoc """
  The trash view offers a way back.

  `Storage.restore_file/1` and the browser's own `restore_selected` have
  always worked. Nothing rendered a control for either, so the trash held
  Move and Delete Permanently and nothing else, and the only Restore button
  in the app was on a file's details page — reachable from the trash only by
  opening the file, then the viewer's Details link. Reported, reasonably, as
  "deleting works, restoring doesn't; it's stuck".

  These read the templates: what is at stake is whether a control is rendered
  at all, which is exactly what no other test was watching.
  """

  use ExUnit.Case, async: true

  @browser_ex Path.join(
                __DIR__,
                "../../../lib/phoenix_kit_web/components/media_browser.ex"
              )
  @browser_heex Path.join(
                  __DIR__,
                  "../../../lib/phoenix_kit_web/components/media_browser.html.heex"
                )

  defp ex, do: File.read!(@browser_ex)
  defp heex, do: File.read!(@browser_heex)

  describe "a trashed file can be restored from the view it is in" do
    test "the file's own menu offers it" do
      # The menu a trashed file actually shows (`file_row_menu`, the kebab on
      # a tile and a row). The list-view menu below is the other one.
      src = ex()

      assert src =~ ~s|phx-click="restore_file"|,
             "the trash view's file menu must offer a restore"

      assert src =~ ~s|:if={not @readonly and @filter_trash}|,
             "…in the trash view only — an active file has nothing to restore"
    end

    test "the list view's row menu offers it too" do
      assert heex() =~ ~s|phx-click="restore_file"|
    end

    test "a selection can be restored in one go" do
      # `restore_selected` handles files AND folders and has existed all
      # along; this is the button for it.
      assert heex() =~ ~s|phx-click="restore_selected"|
    end

    test "a trashed folder can be restored as well" do
      assert heex() =~ ~s|phx-click="restore_folder"|
    end

    test "Move stays available in the trash, because that is the way out" do
      # Moving a trashed file into a folder restores it there, so the control
      # belongs in the trash view rather than being hidden from it.
      assert heex() =~ "Move stays in the trash view"
    end
  end

  describe "the handlers behind those controls" do
    test "exist for one file, one folder and a selection" do
      src = ex()

      for event <- ~w(restore_file restore_folder restore_selected) do
        assert src =~ ~s|def handle_event("#{event}"|, "#{event} needs a handler"
      end
    end

    test "refuse to run in a readonly browser" do
      src = ex()

      for event <- ~w(restore_file restore_folder) do
        assert src =~
                 ~s|def handle_event("#{event}", _params, socket)\n      when socket.assigns.readonly == true do|,
               "#{event} must be refused in a readonly browser, like every other write"
      end
    end

    test "are on the write list, so a contributor cannot restore someone else's file" do
      # `@write_events` is what the `own_files_only` guard checks before any
      # handler runs. A write missing from it is a write nobody is guarding.
      src = ex()
      list = src |> String.split("@write_events ~w(") |> Enum.at(1) |> String.split(")") |> hd()

      for event <- ~w(restore_file restore_folder restore_selected) do
        assert String.contains?(list, event), "#{event} is missing from @write_events"
      end
    end
  end
end
