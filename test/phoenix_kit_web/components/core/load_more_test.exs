defmodule PhoenixKitWeb.Components.Core.LoadMoreTest do
  @moduledoc """
  Render tests for `<.load_more>`. Pins three branches:

  - total=0 → component renders nothing (empty list / not loaded yet)
  - 0<loaded<total → status line + Load more button
  - loaded>=total → status line only, no button (fully loaded)
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.Pagination, only: [load_more: 1]

  describe "load_more/1" do
    test "total=0 renders nothing" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.load_more loaded={0} total={0} />
        """)

      refute result =~ "Showing"
      refute result =~ "Load more"
    end

    test "loaded < total → status text + Load more button" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.load_more loaded={50} total={120} noun_plural="projects" />
        """)

      assert result =~ "Showing 50 of 120 projects"
      assert result =~ "Load more"
      assert result =~ ~s(phx-click="load_more")
      assert result =~ ~s(phx-disable-with="Loading…")
    end

    test "loaded >= total → status text but no button" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.load_more loaded={120} total={120} noun_plural="projects" />
        """)

      assert result =~ "Showing 120 of 120 projects"
      refute result =~ ~s(>Load more</button>)
    end

    test "custom on_load_more rewires the click event" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.load_more loaded={10} total={50} on_load_more="my_load_event" />
        """)

      assert result =~ ~s(phx-click="my_load_event")
    end

    test "loaded == 0 with total > 0 renders the button" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.load_more loaded={0} total={5} noun_plural="items" />
        """)

      assert result =~ "Showing 0 of 5 items"
      assert result =~ "Load more"
    end
  end
end
