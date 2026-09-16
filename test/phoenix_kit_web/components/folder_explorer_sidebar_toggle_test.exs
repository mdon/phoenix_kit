defmodule PhoenixKitWeb.Components.FolderExplorerSidebarToggleTest do
  @moduledoc """
  The sidebar collapse must be optimistic: both panes render in the DOM
  (one carrying `hidden`) and the chevrons swap them with client-side
  JS commands before pushing `toggle_sidebar`. It used to be an
  if/else — one pane in the DOM, visibility decided by the assign — so
  the chevron waited a full round trip plus the re-render it dragged
  in, which read as the collapse being slow.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.FolderExplorer

  defp render_explorer(assigns) do
    render_component(
      &FolderExplorer.folder_explorer/1,
      Map.merge(
        %{id: "fx", myself: nil, folder_tree: [], expanded_folders: MapSet.new()},
        assigns
      )
    )
  end

  test "expanded: both panes are in the DOM, the strip hidden" do
    html = render_explorer(%{sidebar_collapsed: false})

    assert html =~ ~s(id="fx-collapsed")
    assert html =~ ~s(id="fx-expanded")

    # The strip carries hidden; the expanded wrapper does not.
    assert [strip] = Regex.run(~r/<div\s+id="fx-collapsed"[^>]*>/, html)
    assert strip =~ "hidden"
    assert [pane] = Regex.run(~r/<div\s+id="fx-expanded"[^>]*>/, html)
    refute pane =~ "hidden"
  end

  test "collapsed: the same two panes, roles reversed" do
    html = render_explorer(%{sidebar_collapsed: true})

    assert [strip] = Regex.run(~r/<div\s+id="fx-collapsed"[^>]*>/, html)
    refute strip =~ "hidden"
    assert [pane] = Regex.run(~r/<div\s+id="fx-expanded"[^>]*>/, html)
    assert pane =~ "hidden"

    # The folder tree is still THERE while collapsed — that is what makes
    # reopening instant.
    assert html =~ "Folders"
  end

  test "both chevrons swap the panes client-side, then push toggle_sidebar" do
    for collapsed <- [false, true] do
      html = render_explorer(%{sidebar_collapsed: collapsed})

      # Two chevrons (collapse + show), each carrying the full JS chain:
      # toggle both panes' hidden, then the server push. An if/else here —
      # or a bare phx-click="toggle_sidebar" — would put the round trip
      # back in front of the visual.
      toggles =
        Regex.scan(~r/phx-click="(\[[^"]*toggle_sidebar[^"]*\])"/, html)
        |> Enum.map(fn [_, payload] -> payload end)

      assert length(toggles) == 2,
             "expected both chevrons to carry the optimistic toggle (collapsed: #{collapsed})"

      for payload <- toggles do
        decoded = payload |> String.replace("&quot;", "\"") |> Jason.decode!()
        ops = Enum.map(decoded, &List.first/1)

        assert ops == ["toggle_class", "toggle_class", "push"],
               "chevron must flip both panes before the push, got: #{inspect(ops)}"

        targets =
          for ["toggle_class", %{"names" => ["hidden"], "to" => to}] <- decoded, do: to

        assert Enum.sort(targets) == ["#fx-collapsed", "#fx-expanded"]
        assert [_, _, ["push", %{"event" => "toggle_sidebar"}]] = decoded
      end
    end
  end

  test "with a component target, the push carries it" do
    html =
      render_explorer(%{sidebar_collapsed: false, myself: %Phoenix.LiveComponent.CID{cid: 7}})

    assert [_, payload] = Regex.run(~r/phx-click="(\[[^"]*toggle_sidebar[^"]*\])"/, html)
    decoded = payload |> String.replace("&quot;", "\"") |> Jason.decode!()
    assert [_, _, ["push", %{"event" => "toggle_sidebar", "target" => 7}]] = decoded
  end
end
