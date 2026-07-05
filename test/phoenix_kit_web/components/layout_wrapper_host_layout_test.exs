defmodule PhoenixKitWeb.Components.LayoutWrapperHostLayoutTest do
  @moduledoc """
  Regression coverage for `LayoutWrapper.render_host_layout/1` — the LiveView
  `:layout` adapter wired in `PhoenixKitWeb.__using__(:live_view)`.

  Phoenix invokes a LiveView `:layout` with `@inner_content` only, never an
  `@inner_block` slot. Pins that the adapter delegates to the configured host
  layout AND renders the page content whether that host layout uses:

  - `{@inner_content}` — the documented contract; must stay a transparent
    pass-through, AND
  - `render_slot(@inner_block)` — the Phoenix 1.8 function-component idiom;
    used to raise `KeyError: key :inner_block not found` before the adapter.

  `async: false` because it mutates the global `:phoenix_kit, :layout` env; the
  original value is restored in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.LayoutWrapper

  @marker "PHOENIX_KIT_INNER_MARKER"

  # Host layout following the documented `{@inner_content}` contract.
  defmodule InnerContentHost do
    use Phoenix.Component

    def frontend(assigns) do
      ~H"""
      <div id="host-shell">{@inner_content}</div>
      """
    end
  end

  # Host layout written in the Phoenix 1.8 function-component idiom. This is the
  # shape that crashed with KeyError before the adapter synthesized inner_block.
  defmodule InnerBlockHost do
    use Phoenix.Component

    slot :inner_block, required: true

    def frontend(assigns) do
      ~H"""
      <div id="host-shell">{render_slot(@inner_block)}</div>
      """
    end
  end

  setup do
    original = Application.get_env(:phoenix_kit, :layout)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:phoenix_kit, :layout)
        value -> Application.put_env(:phoenix_kit, :layout, value)
      end
    end)

    :ok
  end

  defp render_via_adapter(host_module) do
    Application.put_env(:phoenix_kit, :layout, {host_module, :frontend})

    %{__changed__: nil, inner_content: @marker}
    |> LayoutWrapper.render_host_layout()
    |> rendered_to_string()
  end

  describe "render_host_layout/1" do
    test "host layout using {@inner_content} renders page content (transparent pass-through)" do
      html = render_via_adapter(InnerContentHost)

      assert html =~ ~s(id="host-shell")
      assert html =~ @marker
    end

    test "host layout using render_slot(@inner_block) renders content without KeyError" do
      html = render_via_adapter(InnerBlockHost)

      assert html =~ ~s(id="host-shell")
      assert html =~ @marker
    end
  end
end
