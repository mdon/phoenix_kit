defmodule PhoenixKitWeb.Components.Core.BulkSelectTest do
  @moduledoc """
  Render tests for the three client-side bulk-select components.
  Selection state lives in the DOM, owned by the `BulkSelectScope`
  hook — these tests pin the wire-format (attribute names, hook
  identifiers, default labels) the hook expects to find.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.BulkSelect

  describe "bulk_select_scope/1" do
    test "renders div with PkScope hook + data-bulk-total" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_select_scope id="my-scope" total_count={17}>
          <span>child</span>
        </.bulk_select_scope>
        """)

      assert result =~ ~s(id="my-scope")
      assert result =~ ~s(phx-hook="BulkSelectScope")
      assert result =~ ~s(data-bulk-total="17")
      assert result =~ "<span>child</span>"
    end

    test "respects custom class" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_select_scope id="s" total_count={0} class="my-custom-class">
          x
        </.bulk_select_scope>
        """)

      assert result =~ "my-custom-class"
    end
  end

  describe "bulk_select_header_cell/1" do
    test "renders th + select-all checkbox with hook data attributes" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_select_header_cell id="select-all-projects" />
        """)

      assert result =~ "<th"
      assert result =~ ~s(id="select-all-projects")
      assert result =~ ~s(data-bulk-role="select-all")
      assert result =~ ~s(type="checkbox")
      # Default aria_label.
      assert result =~ "Toggle select all"
    end

    test "custom aria_label overrides default" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_select_header_cell id="s" aria_label="Pick all the projects" />
        """)

      assert result =~ "Pick all the projects"
    end
  end

  describe "bulk_select_cell/1" do
    test "renders per-row checkbox bound to the uuid" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_select_cell value="11111111-1111-7000-8000-000000000001" />
        """)

      assert result =~ ~s(data-bulk-role="row")
      assert result =~ ~s(data-uuid="11111111-1111-7000-8000-000000000001")
      assert result =~ ~s(type="checkbox")
    end
  end

  describe "bulk_actions_toolbar/1" do
    test "renders reorder button with the configured event name" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar on_open_reorder="open_reorder_modal" />
        """)

      assert result =~ ~s(data-bulk-action="open_reorder_modal")
      # Default reorder_gate is :always — the button shows the "Reorder all" label by default.
      assert result =~ "Reorder all"
      # Reorder button (the one with `data-bulk-action`) must not start
      # hidden. The Clear button always carries `style="display: none;"`
      # because it hides when selection is empty — so we can't just
      # check the absence of that style globally.
      reorder_chunk =
        result
        |> String.split(~s(data-bulk-action="open_reorder_modal"))
        |> Enum.at(1)
        |> String.slice(0, 200)

      refute reorder_chunk =~ ~s(style="display: none;)
    end

    test ":multi gate hides the reorder button initially" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar on_open_reorder="open_reorder_modal" reorder_gate={:multi} />
        """)

      # The button still renders but is hidden via inline style; the hook
      # flips it visible when 2+ rows are selected.
      assert result =~ ~s(data-bulk-show="has-multiple")
      assert result =~ ~s(style="display: none;)
    end

    test "delete button only renders when on_bulk_delete is set" do
      assigns = %{}

      without =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar on_open_reorder="r" />
        """)

      refute without =~ "Delete"

      with_delete =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar on_open_reorder="r" on_bulk_delete="bulk_delete" />
        """)

      assert with_delete =~ ~s(data-bulk-action="bulk_delete")
      assert with_delete =~ "Delete"
    end

    test "delete button does NOT render when allow_delete is false even if on_bulk_delete given" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar
          on_open_reorder="r"
          on_bulk_delete="bulk_delete"
          allow_delete={false}
        />
        """)

      refute result =~ ~s(data-bulk-action="bulk_delete")
    end

    test "noun_singular / noun_plural feed the reorder label template" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar
          on_open_reorder="r"
          noun_singular="project"
          noun_plural="projects"
        />
        """)

      # The translated "%{count} selected" template ships as the data
      # attr the hook reads at click time. Pin its presence.
      assert result =~ ~s(data-bulk-label-selected)
    end

    test "reorder_dialog_id wires the dialog-id for instant client open" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar
          on_open_reorder="open_reorder_modal"
          reorder_dialog_id="reorder-modal"
        />
        """)

      assert result =~ ~s(data-bulk-opens-dialog="reorder-modal")
    end

    test "leading slot renders before action buttons" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.bulk_actions_toolbar on_open_reorder="r">
          <:leading><span class="sort-here">SORT</span></:leading>
        </.bulk_actions_toolbar>
        """)

      # `sort-here` should appear before `data-bulk-action`.
      sort_idx = :binary.match(result, "sort-here") |> elem(0)
      action_idx = :binary.match(result, "data-bulk-action") |> elem(0)
      assert sort_idx < action_idx
    end
  end
end
