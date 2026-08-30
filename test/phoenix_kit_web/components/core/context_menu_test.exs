defmodule PhoenixKitWeb.Components.Core.ContextMenuTest do
  @moduledoc """
  Render tests for `<.context_menu>`. The gesture and the positioning live in
  the `ContextMenu` JS hook and are not covered here; what these pin is the
  contract the hook reads out of the DOM:

  - the hook is attached and every config attribute reaches it
  - the menu content is a portalable `<ul role="menu">` with a stable id
  - the heading `<li>` is present-but-hidden, and omitted when `show_label` is off
  - items render as `role="menuitem"` (what the hook stamps `phx-value-*` onto)
  - `long_press={false}` and a custom `long_press_ms` survive to the attributes
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.ContextMenu

  defp render_menu(assigns) do
    assigns = Map.put_new(assigns, :id, "ctx")

    rendered_to_string(~H"""
    <.context_menu
      id={@id}
      selector={assigns[:selector] || "[data-context-value]"}
      within={assigns[:within]}
      value_name={assigns[:value_name] || "uuid"}
      value_attr={assigns[:value_attr] || "data-context-value"}
      label_attr={assigns[:label_attr] || "data-context-label"}
      show_label={Map.get(assigns, :show_label, true)}
      long_press={Map.get(assigns, :long_press, true)}
      long_press_ms={assigns[:long_press_ms] || 450}
    >
      <.context_menu_button phx-click="rename" icon="hero-pencil" label="Rename" />
      <.context_menu_divider />
      <.context_menu_button phx-click="delete" icon="hero-trash" label="Delete" variant="error" />
    </.context_menu>
    """)
  end

  test "attaches the hook and forwards the selector" do
    html = render_menu(%{selector: "[data-ctx-folder]"})

    assert html =~ ~s(phx-hook="ContextMenu")
    assert html =~ ~s(data-context-selector="[data-ctx-folder]")
  end

  test "menu content is a role=menu list with a stable derived id" do
    html = render_menu(%{id: "folder-menu"})

    assert html =~ ~s(id="folder-menu-content")
    assert html =~ ~s(role="menu")
    assert html =~ "data-context-menu-content"
    # Hidden until the hook positions it, and fixed so the portal to <body>
    # can place it at the pointer.
    assert html =~ "hidden fixed"
  end

  test "items render as menuitems for the hook to stamp" do
    html = render_menu(%{})

    assert html =~ ~s(role="menuitem")
    assert html =~ ~s(phx-click="rename")
    assert html =~ ~s(phx-click="delete")
    assert html =~ ~s(role="separator")
    # The value is stamped client-side per row, never rendered server-side.
    refute html =~ "phx-value-uuid"
  end

  test "value and label attribute names reach the hook" do
    html =
      render_menu(%{
        value_attr: "data-draggable-folder",
        value_name: "folder-uuid",
        label_attr: "data-folder-name"
      })

    assert html =~ ~s(data-context-value-attr="data-draggable-folder")
    assert html =~ ~s(data-context-value-name="folder-uuid")
    assert html =~ ~s(data-context-label-attr="data-folder-name")
  end

  test "a list of value names is stamped as a comma-separated list" do
    # KB's folder menu needs both: `start_rename_folder` takes `folder-uuid`,
    # `trash_folder` takes `folder_uuid`. Stamping both beats a shim clause
    # that exists only to rename a key.
    html = render_menu(%{value_name: ["folder-uuid", "folder_uuid"]})

    assert html =~ ~s(data-context-value-name="folder-uuid,folder_uuid")
  end

  test "heading renders hidden by default and is omitted when disabled" do
    html = render_menu(%{})
    assert html =~ "data-context-menu-label"

    without = render_menu(%{show_label: false})
    refute without =~ "data-context-menu-label"
    # With no heading element there is nothing for the hook to fill, so the
    # attribute it reads must not claim otherwise.
    refute without =~ "data-context-label-attr"
  end

  test "within scopes the selector when given, and is omitted when not" do
    scoped = render_menu(%{within: "#kb-sidebar"})
    assert scoped =~ ~s(data-context-within="#kb-sidebar")

    refute render_menu(%{}) =~ "data-context-within"
  end

  test "long press config survives to the attributes" do
    on = render_menu(%{long_press_ms: 600})
    assert on =~ ~s(data-context-long-press="true")
    assert on =~ ~s(data-context-long-press-ms="600")

    assert render_menu(%{long_press: false}) =~ ~s(data-context-long-press="false")
  end
end
