defmodule PhoenixKitWeb.Components.Core.TableDefaultTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.TableDefault

  # ── sort_header_cell/1 ─────────────────────────────────────────

  describe "sort_header_cell/1" do
    test "renders th with label only when sort is nil" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:name} sort={nil}>Name</.sort_header_cell>
        """)

      assert result =~ "<th"
      assert result =~ "Name"
      refute result =~ "<button"
      refute result =~ "phx-click"
    end

    test "renders button with toggle_sort event for active column ascending" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :asc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="toggle_sort")
      assert result =~ ~s(phx-value-by="foo")
      assert result =~ "hero-chevron-up-mini"
    end

    test "renders button with chevron-down for active column descending" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :desc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="toggle_sort")
      assert result =~ "hero-chevron-down-mini"
    end

    test "renders button without chevron for inactive column" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:bar} sort={%{by: :foo, dir: :asc}}>Bar</.sort_header_cell>
        """)

      assert result =~ "<button"
      refute result =~ "hero-chevron-up-mini"
      refute result =~ "hero-chevron-down-mini"
    end

    test "align right adds justify-end class to button" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:amount} sort={%{by: :amount, dir: :asc}} align={:right}>
          Amount
        </.sort_header_cell>
        """)

      assert result =~ "justify-end"
    end

    test "custom event and target are passed through" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell
          field={:name}
          sort={%{by: :name, dir: :asc}}
          event="my_sort"
          target="#my-table"
        >
          Name
        </.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="my_sort")
      assert result =~ ~s(phx-target="#my-table")
    end
  end

  # ── search_toolbar/1 ───────────────────────────────────────────

  describe "search_toolbar/1" do
    test "renders input with default 300ms debounce" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert result =~ ~s(phx-debounce="300")
      assert result =~ ~s(phx-change="search")
      assert result =~ "hero-magnifying-glass"
    end

    test "respects value attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="hello" />
        """)

      assert result =~ ~s(value="hello")
    end

    test "respects placeholder attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" placeholder="Search users..." />
        """)

      assert result =~ ~s(placeholder="Search users...")
    end

    test "respects on_change attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_change="filter_users" />
        """)

      assert result =~ ~s(phx-change="filter_users")
    end

    test "wraps in form when on_submit is set" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_submit="do_search" />
        """)

      assert result =~ "<form"
      assert result =~ ~s(phx-submit="do_search")
    end

    test "no form wrapper when on_submit is nil" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      refute result =~ "<form"
    end

    test "default placeholder uses dgettext fallback" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert result =~ ~s(placeholder="Search...")
    end
  end
end
