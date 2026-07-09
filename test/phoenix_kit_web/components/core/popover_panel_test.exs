defmodule PhoenixKitWeb.Components.Core.PopoverPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.PopoverPanel

  defp render(template), do: rendered_to_string(template)

  test "renders hidden by default with content and close wiring" do
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="test-panel">
        <p>Panel content</p>
      </.popover_panel>
      """)

    assert html =~ ~s(id="test-panel")
    assert html =~ "Panel content"
    # closed until the client-side toggle runs — no server round-trip to open
    assert html =~ ~s(class="hidden fixed)
    # Escape hides client-side (a JS command, not a named server event)
    assert html =~ ~s(phx-window-keydown)
    assert html =~ ~s(phx-key="escape")
    assert html =~ ~s(role="dialog")
  end

  test "toggle_popover/2 and hide_popover/2 emit client-side JS targeting the id" do
    toggle = toggle_popover("test-panel") |> Phoenix.json_library().encode!()
    hide = hide_popover("test-panel") |> Phoenix.json_library().encode!()

    assert toggle =~ "toggle"
    assert toggle =~ "#test-panel"
    assert hide =~ "hide"
    assert hide =~ "#test-panel"
  end

  test "the card stacks ABOVE the click-away backdrop" do
    # Regression: the card must be a positioned element with a z-index over
    # the fixed backdrop, or every click/scroll inside the panel lands on
    # the backdrop and closes it.
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="stack-panel">
        <p>content</p>
      </.popover_panel>
      """)

    assert html =~ "absolute inset-x-2 top-12 z-10"
    assert html =~ "sm:relative"
  end

  test "align start/end picks the anchored edge" do
    assigns = %{}

    end_html =
      render(~H"""
      <.popover_panel id="p1">content</.popover_panel>
      """)

    start_html =
      render(~H"""
      <.popover_panel id="p2" align="start">content</.popover_panel>
      """)

    assert end_html =~ "sm:right-0"
    assert start_html =~ "sm:left-0"
  end

  test "width_class and class merge onto the card" do
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="p3" width_class="sm:w-72" class="p-1">
        content
      </.popover_panel>
      """)

    assert html =~ "sm:w-72"
    assert html =~ "p-1"
  end
end
