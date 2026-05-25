defmodule PhoenixKitWeb.Components.Core.ReorderModalTest do
  @moduledoc """
  Render tests for `<.reorder_modal>`. The component is shell + radio
  UI around `<.modal>` with `keep_in_dom={true}` and a strategy-radio
  form. Tests pin:

  - Scope label switches between "Reorder all N" and "Reorder N selected"
  - Strategy radios render with the consumer-supplied values + labels
  - The Apply button submits the strategy radio form
  - The dialog stays in the DOM (data-show flip drives visibility)
  - `phx-disable-with` on Apply blocks rapid resubmits
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.ReorderModal

  @strategies [
    {"name_asc", "A → Z by name"},
    {"name_desc", "Z → A by name"},
    {"created_desc", "Newest first"},
    {"created_asc", "Oldest first"},
    {"reverse", "Reverse current order"}
  ]

  describe "reorder_modal/1" do
    test "renders all strategy radios with their values + labels" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={0}
          total_count={10}
          strategies={@strategies}
          noun_singular="project"
          noun_plural="projects"
        />
        """)

      for {value, label} <- @strategies do
        assert result =~ ~s(value="#{value}")
        assert result =~ label
      end
    end

    test "selected_count=0 → 'Reorder all' label" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={0}
          total_count={42}
          strategies={@strategies}
          noun_singular="project"
          noun_plural="projects"
        />
        """)

      assert result =~ "Reorder all 42 projects"
    end

    test "selected_count=1 → singular 'selected' label" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={1}
          total_count={42}
          strategies={@strategies}
          noun_singular="project"
          noun_plural="projects"
        />
        """)

      assert result =~ "1 selected project"
    end

    test "selected_count=N>1 → 'N selected projects' label" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={3}
          total_count={42}
          strategies={@strategies}
          noun_singular="project"
          noun_plural="projects"
        />
        """)

      assert result =~ "3 selected projects"
    end

    test "kept in DOM regardless of show=false (data-show='false')" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
        />
        """)

      assert result =~ "<dialog"
      assert result =~ ~s(data-show="false")
    end

    test "show=true flips data-show to true" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={true}
          on_close="close_event"
          on_apply="apply_event"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
        />
        """)

      assert result =~ ~s(data-show="true")
    end

    test "wires on_apply as the form's phx-submit" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={true}
          on_close="close"
          on_apply="my_apply_event"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
        />
        """)

      assert result =~ ~s(phx-submit="my_apply_event")
    end

    test "Apply button has phx-disable-with to prevent double-submit" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={true}
          on_close="close"
          on_apply="apply"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
        />
        """)

      assert result =~ ~s(phx-disable-with="Applying…")
    end

    test "respects custom id (used as dialog id + form id prefix)" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={false}
          on_close="close"
          on_apply="apply"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
          id="my-reorder"
        />
        """)

      assert result =~ ~s(id="my-reorder")
      assert result =~ ~s(id="my-reorder-form")
    end

    test "Cancel button fires on_close" do
      assigns = %{strategies: @strategies}

      result =
        rendered_to_string(~H"""
        <.reorder_modal
          show={true}
          on_close="my_close_event"
          on_apply="apply"
          selected_count={0}
          total_count={1}
          strategies={@strategies}
        />
        """)

      assert result =~ ~s(phx-click="my_close_event")
    end
  end
end
