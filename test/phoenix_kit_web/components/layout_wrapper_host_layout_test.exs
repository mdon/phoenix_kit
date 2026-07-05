defmodule PhoenixKitWeb.Components.LayoutWrapperHostLayoutTest do
  @moduledoc """
  Regression coverage for `LayoutWrapper.render_host_layout/1` — the LiveView
  `:layout` adapter wired in `PhoenixKitWeb.__using__(:live_view)`.

  Phoenix invokes a LiveView `:layout` with `@inner_content` (a
  `%Phoenix.LiveView.Rendered{}`, NOT a binary) and never an `@inner_block`
  slot. These tests feed a real `%Rendered{}` so they exercise the production
  data shape — an earlier version fed a binary string, which hit
  `Phoenix.HTML.raw/1`'s binary clause and masked a `raw(%Rendered{})`
  FunctionClauseError.

  Pins:
  - `{@inner_content}` host layout renders content (transparent pass-through),
  - `render_slot(@inner_block)` host layout renders content (no KeyError, and
    no `raw(%Rendered{})` crash — the synthetic slot yields the `%Rendered{}`
    verbatim),
  - the double-wrap dedup: when the LiveView already applied the host chrome
    (flag set), the adapter passes `@inner_content` through instead of
    re-wrapping.

  `async: false` because it mutates the global `:phoenix_kit, :layout` env; the
  original value is restored in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
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
  # shape that crashed (KeyError, then FunctionClauseError) before the fix.
  defmodule InnerBlockHost do
    use Phoenix.Component

    slot :inner_block, required: true

    def frontend(assigns) do
      ~H"""
      <div id="host-shell">{render_slot(@inner_block)}</div>
      """
    end
  end

  # A real %Phoenix.LiveView.Rendered{} — what Phoenix passes as @inner_content.
  defp inner_content do
    assigns = %{__changed__: nil, marker: @marker}

    ~H"""
    <span id="the-inner">{@marker}</span>
    """
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

    %{__changed__: nil, inner_content: inner_content()}
    |> LayoutWrapper.render_host_layout()
    |> rendered_to_string()
  end

  describe "render_host_layout/1" do
    test "host layout using {@inner_content} renders page content (transparent pass-through)" do
      html = render_via_adapter(InnerContentHost)

      assert html =~ ~s(id="host-shell")
      assert html =~ ~s(id="the-inner")
      assert html =~ @marker
    end

    test "host layout using render_slot(@inner_block) renders content (no KeyError / no raw crash)" do
      html = render_via_adapter(InnerBlockHost)

      assert html =~ ~s(id="host-shell")
      assert html =~ ~s(id="the-inner")
      assert html =~ @marker
    end

    test "passes @inner_content through when host chrome was already applied (no double-wrap)" do
      Application.put_env(:phoenix_kit, :layout, {InnerBlockHost, :frontend})
      # Simulate the LiveView's own render having already applied the host
      # layout via app_layout -> render_modern_parent_layout.
      Process.put(:phoenix_kit_host_chrome_rendered, true)

      html =
        %{__changed__: nil, inner_content: inner_content()}
        |> LayoutWrapper.render_host_layout()
        |> rendered_to_string()

      # Content present exactly once; the host shell was NOT re-applied.
      assert html =~ @marker
      assert html =~ ~s(id="the-inner")
      refute html =~ ~s(id="host-shell")
      # Flag consumed so it can't leak into a later render.
      refute Process.get(:phoenix_kit_host_chrome_rendered)
    end
  end
end
