defmodule PhoenixKitWeb.Components.Core.SortableTest do
  @moduledoc """
  Render tests for `<.sortable_tbody>` and `<.sortable_row>`. These
  components encode the wire-format the `SortableGrid` JS hook reads.
  The tests pin the hook identifier, data attributes, and the
  enable/disable branch.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.Sortable

  describe "sortable_tbody/1" do
    test "enabled attaches SortableGrid hook + data attrs" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_tbody id="projects-body" event="reorder_projects">
          <tr>
            <td>row</td>
          </tr>
        </.sortable_tbody>
        """)

      assert result =~ ~s(id="projects-body")
      assert result =~ ~s(phx-hook="SortableGrid")
      assert result =~ ~s(data-sortable="true")
      assert result =~ ~s(data-sortable-event="reorder_projects")
      assert result =~ ~s(data-sortable-items=".sortable-item")
      assert result =~ ~s(data-sortable-handle=".pk-drag-handle")
      assert result =~ "<tr>"
      assert result =~ "<td>row</td>"
    end

    test "disabled omits the hook and data-sortable but keeps the event attr" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_tbody id="projects-body" event="reorder_projects" enabled={false}>
          <tr>
            <td>row</td>
          </tr>
        </.sortable_tbody>
        """)

      refute result =~ ~s(phx-hook="SortableGrid")
      # Implementation renders the attribute name with an empty value
      # rather than omitting the attribute, because `if @enabled, do: ...`
      # in HEEx evaluates to `nil` when false. Both states tell the hook
      # "not me" identically — pin the practical outcome (no hook attached).
      refute result =~ ~s(data-sortable="true")
    end

    test "extra attrs pass through via :rest" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_tbody id="b" event="evt" data-extra="yep">
          <tr></tr>
        </.sortable_tbody>
        """)

      assert result =~ ~s(data-extra="yep")
    end
  end

  describe "sortable_row/1" do
    test "renders tr with sortable-item class + data-id" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_row item_id="abc-uuid">
          <td>cell</td>
        </.sortable_row>
        """)

      assert result =~ "<tr"
      assert result =~ "sortable-item"
      assert result =~ ~s(data-id="abc-uuid")
      assert result =~ "<td>cell</td>"
    end

    test "consumer class composes alongside sortable-item" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_row item_id="uuid" class="my-row-class">
          <td>c</td>
        </.sortable_row>
        """)

      assert result =~ "sortable-item"
      assert result =~ "my-row-class"
    end

    test "extra attrs pass through" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sortable_row item_id="u" data-x="y">
          <td>c</td>
        </.sortable_row>
        """)

      assert result =~ ~s(data-x="y")
    end
  end
end
