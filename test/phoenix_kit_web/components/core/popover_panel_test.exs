defmodule PhoenixKitWeb.Components.Core.PopoverPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.PopoverPanel

  defp render(template), do: rendered_to_string(template)

  test "renders the panel with content, backdrop, and close wiring" do
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="test-panel" on_close="close_it">
        <p>Panel content</p>
      </.popover_panel>
      """)

    assert html =~ ~s(id="test-panel")
    assert html =~ "Panel content"
    # Escape closes
    assert html =~ ~s(phx-window-keydown="close_it")
    assert html =~ ~s(phx-key="escape")
    # backdrop click closes
    assert html =~ ~s(phx-click="close_it")
    assert html =~ ~s(role="dialog")
  end

  test "the card stacks ABOVE the click-away backdrop" do
    # Regression: the card must be a positioned element with a z-index over
    # the fixed backdrop, or every click/scroll inside the panel lands on
    # the backdrop and closes it.
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="stack-panel" on_close="close_it">
        <p>content</p>
      </.popover_panel>
      """)

    [_before, card_and_after] = String.split(html, "card bg-base-100", parts: 2)
    _ = card_and_after

    # the card div carries z-10 + positioning in BOTH breakpoints
    assert html =~ "absolute inset-x-2 top-12 z-10"
    assert html =~ "sm:relative"
  end

  test "align start/end picks the anchored edge" do
    assigns = %{}

    end_html =
      render(~H"""
      <.popover_panel id="p1" on_close="x">content</.popover_panel>
      """)

    start_html =
      render(~H"""
      <.popover_panel id="p2" on_close="x" align="start">content</.popover_panel>
      """)

    assert end_html =~ "sm:right-0"
    assert start_html =~ "sm:left-0"
  end

  test "width_class and class merge onto the card" do
    assigns = %{}

    html =
      render(~H"""
      <.popover_panel id="p3" on_close="x" width_class="sm:w-72" class="p-1">
        content
      </.popover_panel>
      """)

    assert html =~ "sm:w-72"
    assert html =~ "p-1"
  end
end
