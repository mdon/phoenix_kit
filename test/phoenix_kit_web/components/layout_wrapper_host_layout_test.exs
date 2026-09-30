defmodule PhoenixKitWeb.Components.LayoutWrapperHostLayoutTest do
  @moduledoc """
  Regression coverage for `LayoutWrapper.apply_host_layout/3` — the single place
  a host's configured `config :phoenix_kit, layout:` is applied (the native
  `:layout` is a pure passthrough, so this is invoked once per page via
  `app_layout`).

  Pins that a host layout renders the page body — exactly once, no double-wrap —
  whether it uses:

  - `{@inner_content}` (the documented contract), or
  - `render_slot(@inner_block)` (the Phoenix 1.8 function-component idiom).

  `apply_host_layout/3` is given an `inner_block` slot and derives a lazy
  `@inner_content` from it, so both conventions work off the same slot.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.LayoutWrapper

  @marker "PK_BODY_MARKER"

  # Host layout following the documented `{@inner_content}` contract.
  defmodule InnerContentHost do
    use Phoenix.Component

    def frontend(assigns) do
      ~H"""
      <div id="host-shell">{@inner_content}</div>
      """
    end
  end

  # Host layout written in the Phoenix 1.8 function-component idiom.
  defmodule InnerBlockHost do
    use Phoenix.Component

    slot :inner_block, required: true

    def frontend(assigns) do
      ~H"""
      <div id="host-shell">{render_slot(@inner_block)}</div>
      """
    end
  end

  # A realistic page body, as a %Rendered{} produced by an inner_block slot.
  defp body_rendered do
    assigns = %{__changed__: nil}

    ~H"""
    <span id="the-body">PK_BODY_MARKER</span>
    """
  end

  # Assigns as app_layout would hand them to apply_host_layout/3: an inner_block
  # slot, no inner_content.
  defp assigns_with_block do
    %{
      __changed__: nil,
      inner_block: [%{inner_block: fn _slot, _idx -> body_rendered() end}]
    }
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1

  describe "apply_host_layout/3" do
    test "host layout using {@inner_content} renders the body exactly once" do
      html =
        assigns_with_block()
        |> LayoutWrapper.apply_host_layout(InnerContentHost, :frontend)
        |> rendered_to_string()

      assert html =~ ~s(id="host-shell")
      assert html =~ ~s(id="the-body")
      assert occurrences(html, @marker) == 1
    end

    test "host layout using render_slot(@inner_block) renders the body exactly once" do
      html =
        assigns_with_block()
        |> LayoutWrapper.apply_host_layout(InnerBlockHost, :frontend)
        |> rendered_to_string()

      assert html =~ ~s(id="host-shell")
      assert html =~ ~s(id="the-body")
      assert occurrences(html, @marker) == 1
    end
  end

  describe "mark_kit_content/1 — the kit's page inside a host layout" do
    test "the body is wrapped in a display:contents marker with the phone input style" do
      html =
        assigns_with_block()
        |> Map.put(:current_path, "/profile/settings")
        |> LayoutWrapper.mark_kit_content()
        |> LayoutWrapper.apply_host_layout(InnerBlockHost, :frontend)
        |> rendered_to_string()

      assert html =~ ~r{<div id="host-shell">\s*<div data-phoenix-kit class="contents">}
      assert html =~ "<style data-pk-mobile-inputs>"
      assert occurrences(html, @marker) == 1
    end

    test "an admin page is left alone — #admin-drawer already marks it" do
      assigns = Map.put(assigns_with_block(), :current_path, "/admin/users")
      assert LayoutWrapper.mark_kit_content(assigns) == assigns
    end

    test "no inner block, nothing to wrap" do
      assigns = %{__changed__: nil, current_path: "/profile/settings"}
      assert LayoutWrapper.mark_kit_content(assigns) == assigns
    end
  end
end
