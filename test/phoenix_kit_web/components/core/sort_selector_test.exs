defmodule PhoenixKitWeb.Components.Core.SortSelectorTest do
  @moduledoc """
  Render tests for `<.sort_selector>`. Pins:

  - select element renders with the current sort_by + options
  - direction toggle button renders with the flipped direction value
  - direction icon switches between asc/desc heroicons
  - manual mode hides the direction toggle
  - atom-or-string normalization on sort_by, sort_dir, options
  - empty/malformed options → empty render, no crash
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.SortSelector

  @options [
    {:position, "Manual"},
    {:name, "Name"},
    {:inserted_at, "Date created"}
  ]

  describe "sort_selector/1" do
    test "renders form + select with the current sort field" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={@options} />
        """)

      assert result =~ "<form"
      assert result =~ ~s(phx-change="sort_form")
      assert result =~ ~s(name="sort_by")
      # `<.select>` renders the current value's option marked selected.
      assert result =~ "Name"
    end

    test "direction toggle button shows asc icon when sort_dir=:asc" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={@options} />
        """)

      assert result =~ "hero-bars-arrow-up"
      # Click sends the flipped direction.
      assert result =~ ~s(phx-value-sort_dir="desc")
    end

    test "direction toggle button shows desc icon when sort_dir=:desc" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:desc} options={@options} />
        """)

      assert result =~ "hero-bars-arrow-down"
      assert result =~ ~s(phx-value-sort_dir="asc")
    end

    test "manual mode hides the direction toggle button" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector
          sort_by={:position}
          sort_dir={:asc}
          options={@options}
          manual_field={:position}
        />
        """)

      refute result =~ ~s(phx-value-sort_dir)
      refute result =~ "hero-bars-arrow-up"
      refute result =~ "hero-bars-arrow-down"
    end

    test "manual_field as string still matches sort_by atom" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector
          sort_by={:position}
          sort_dir={:asc}
          options={@options}
          manual_field="position"
        />
        """)

      refute result =~ ~s(phx-value-sort_dir)
    end

    test "non-manual sort_by + manual_field set → toggle still visible" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector
          sort_by={:name}
          sort_dir={:asc}
          options={@options}
          manual_field={:position}
        />
        """)

      assert result =~ ~s(phx-value-sort_dir="desc")
    end

    test "unknown sort_dir falls back to :asc" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir="banana" options={@options} />
        """)

      assert result =~ "hero-bars-arrow-up"
    end

    test "atom or string sort_by both work" do
      assigns = %{options: @options}

      r_atom =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={@options} />
        """)

      r_string =
        rendered_to_string(~H"""
        <.sort_selector sort_by="name" sort_dir={:asc} options={@options} />
        """)

      # Both render the form + sort_by select identically.
      assert r_atom =~ ~s(name="sort_by")
      assert r_string =~ ~s(name="sort_by")
    end

    test "empty options list → empty render, no crash" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={[]} />
        """)

      refute result =~ "<form"
    end

    test "nil options → empty render" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={nil} />
        """)

      refute result =~ "<form"
    end

    test "options with one bad row → other rows survive, no crash" do
      assigns = %{options: [{:name, "Name"}, "not_a_tuple", {:created_at, "Created"}]}

      result =
        rendered_to_string(~H"""
        <.sort_selector sort_by={:name} sort_dir={:asc} options={@options} />
        """)

      assert result =~ "Name"
      assert result =~ "Created"
    end

    test "custom event name flows to form + button" do
      assigns = %{options: @options}

      result =
        rendered_to_string(~H"""
        <.sort_selector
          sort_by={:name}
          sort_dir={:asc}
          options={@options}
          event="my_sort"
        />
        """)

      assert result =~ ~s(phx-change="my_sort")
      assert result =~ ~s(phx-click="my_sort")
    end
  end
end
