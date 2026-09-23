defmodule PhoenixKitWeb.Components.FolderTreeLoadingTest do
  @moduledoc """
  A tree click that waits on the server shows it is working. LiveView puts
  `.phx-click-loading` on the clicked element until the reply lands — for a
  folder that is after the new listing has rendered — so the row swaps its
  folder icon for a spinner, and the chevron swaps its own. The chevron's
  spinner answers only to the chevron's click, not to the row it sits in,
  so opening a folder never spins two indicators at once.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitWeb.Components.FolderExplorer

  defp render_node do
    child = %{folder: %Folder{uuid: "child", name: "Masks"}, children: []}

    html =
      render_component(&FolderExplorer.folder_tree_node/1, %{
        node: %{folder: %Folder{uuid: "parent", name: "Catalogue"}, children: [child]},
        current_folder: nil,
        expanded_folders: MapSet.new(),
        myself: nil
      })

    LazyHTML.from_fragment(html)
  end

  defp classes(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
  end

  test "the folder row shows a spinner in place of its icon while it loads" do
    doc = render_node()
    row_button = ~s(button[phx-click="navigate_folder"])

    assert [spinner] = classes(doc, "#{row_button} .loading-spinner")
    assert spinner =~ "hidden"
    assert spinner =~ "[.phx-click-loading_&]:inline-block"

    assert [icon | _] = classes(doc, "#{row_button} .hero-folder")
    assert icon =~ "[.phx-click-loading_&]:hidden"
  end

  test "the chevron spins only for its own click" do
    doc = render_node()
    chevron = ~s(button[phx-click="toggle_folder_expand"])

    assert [spinner] = classes(doc, "#{chevron} > .loading-spinner")
    assert spinner =~ "[.phx-click-loading>&]:inline-block"
    refute spinner =~ "[.phx-click-loading_&]"

    assert [icon] = classes(doc, "#{chevron} > .hero-chevron-right-mini")
    assert icon =~ "[.phx-click-loading>&]:hidden"
  end
end
