defmodule PhoenixKitWeb.Components.TreePickerTest do
  @moduledoc """
  `TreePicker` in a host LiveView the way a form uses it: the host owns the
  value and learns of a pick by message; the component takes only rows its
  tree offers, filters by search, and posts through hidden inputs.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKit.Utils.Tree

  @endpoint PhoenixKitWeb.Endpoint

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.TreePicker

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         test_pid: session["test_pid"],
         tree: session["tree"],
         value: session["value"],
         opts: session["opts"] || %{}
       )}
    end

    def handle_info({TreePicker, id, value}, socket) do
      send(socket.assigns.test_pid, {:picked, id, value})
      {:noreply, assign(socket, :value, value)}
    end

    def handle_info({:set_value, value}, socket), do: {:noreply, assign(socket, :value, value)}

    def handle_event("changed", params, socket) do
      send(socket.assigns.test_pid, {:form_change, params})
      {:noreply, socket}
    end

    def render(assigns) do
      ~H"""
      <form id="host-form" phx-change="changed">
        <.live_component
          module={TreePicker}
          id="picker"
          tree={@tree}
          value={@value}
          name="page[parent_uuid]"
          pickable={Map.get(@opts, :pickable, :all)}
          multiple={Map.get(@opts, :multiple, false)}
          field={Map.get(@opts, :field, false)}
          current={Map.get(@opts, :current)}
          {Map.take(@opts, [:search_placeholder, :disabled])}
        />
      </form>
      """
    end
  end

  defp rec(uuid, parent, name, type),
    do: %{uuid: uuid, parent_uuid: parent, name: name, type: type}

  defp tree do
    [
      Tree.root(
        "Top level",
        Tree.from_flat(
          [
            rec("a", nil, "Kitchen", :shelf),
            rec("b", "a", "Doors", :page),
            rec("c", "b", "Hinges", :page)
          ],
          node: &%{name: &1.name, type: &1.type, icon: "hero-folder"}
        )
      )
    ]
  end

  defp open(opts \\ %{}, value \\ nil) do
    {:ok, view, html} =
      live_isolated(build_conn(), Host,
        session: %{"test_pid" => self(), "tree" => tree(), "value" => value, "opts" => opts}
      )

    {view, html}
  end

  defp pick(view, id), do: view |> element(~s([data-tree-node="#{id}"])) |> render_click()

  test "the root row starts open; picking a row tells the host and posts it" do
    {view, html} = open()
    assert html =~ "Kitchen"
    refute html =~ "Hinges"

    pick(view, "a")
    assert_receive {:picked, "picker", "a"}
    assert render(view) =~ ~s(name="page[parent_uuid]" value="a")
  end

  test "the root row posts blank — no parent" do
    {view, _html} = open()
    pick(view, "root")

    assert_receive {:picked, "picker", "root"}
    assert render(view) =~ ~s(name="page[parent_uuid]" value="")
  end

  test "a picked row's ancestors start open" do
    {_view, html} = open(%{}, "c")
    assert html =~ "Hinges"
  end

  test "a value the parent hands in later opens the rows above it" do
    {view, html} = open()
    refute html =~ "Hinges"

    send(view.pid, {:set_value, "c"})
    assert render(view) =~ "Hinges"
  end

  test "the picker's own pick opens nothing: a whole branch stays closed" do
    {view, _html} = open(%{multiple: true, pickable: [:page]}, [])

    view |> element(~s([data-pick-all="a"])) |> render_click()
    assert_receive {:picked, "picker", ["b", "c"]}
    refute render(view) =~ "Doors"
  end

  test "a row of a type that cannot be picked only opens" do
    {view, _html} = open(%{pickable: [:page]})
    pick(view, "a")

    refute_receive {:picked, _, _}
    assert render(view) =~ "Doors"
  end

  test "an id the tree does not offer is ignored" do
    {view, _html} = open()
    # A crafted event straight to the component (via its hooked search box).
    view |> element("#picker-search") |> render_hook("pick", %{"id" => "forged"})

    refute_receive {:picked, _, _}
  end

  test "search keeps matches and the rows above them, and reaches no form" do
    {view, _html} = open()

    html = view |> element("#picker-search") |> render_hook("search", %{"value" => "hinge"})
    assert html =~ "Hinges"

    html = view |> element("#picker-search") |> render_hook("search", %{"value" => "zzz"})
    assert html =~ "No matches."
    refute_receive {:form_change, _}
  end

  test "multiple: rows toggle in and out, and a branch box takes its whole branch" do
    {view, _html} = open(%{multiple: true, pickable: [:page]}, [])

    view |> element(~s([data-pick-all="a"])) |> render_click()
    assert_receive {:picked, "picker", ["b", "c"]}

    view |> element(~s([data-pick-all="a"])) |> render_click()
    assert_receive {:picked, "picker", []}
  end

  test "field mode shows the path and opens the tree only on Change" do
    {view, html} = open(%{field: true}, "c")

    assert html =~ "Kitchen"
    assert html =~ "Hinges"
    refute html =~ ~s(id="picker-search")

    html = view |> element("#picker-change") |> render_click()
    assert html =~ ~s(id="picker-search")
  end

  test "the search box takes its own hint" do
    {_view, html} = open(%{search_placeholder: "Find a page…"})
    assert html =~ ~s(placeholder="Find a page…")

    {_view, html} = open()
    assert html =~ ~s(placeholder="Search...")
  end

  test "disabled field mode shows the path, offers no Change and posts nothing" do
    {view, html} = open(%{field: true, disabled: true}, "c")

    assert html =~ "Hinges"
    refute html =~ ~s(id="picker-change")
    refute html =~ ~s(name="page[parent_uuid]")

    # A crafted open is refused too.
    html = view |> with_target("#picker") |> render_hook("open_panel", %{})
    refute html =~ ~s(id="picker-search")
  end

  test "the current row carries a badge" do
    {_view, html} = open(%{current: "a"})
    assert html =~ "Current"
  end
end
