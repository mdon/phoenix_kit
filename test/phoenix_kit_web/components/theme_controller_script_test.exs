defmodule PhoenixKitWeb.Components.ThemeControllerScriptTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.ThemeControllerScript

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit, :dashboard_themes) end)
  end

  defp render_script do
    render_component(&ThemeControllerScript.theme_controller_script/1, %{})
  end

  test "every data literal is generated from ThemeConfig, none hand-written" do
    # The predecessor scripts each carried their own base-map literal, which
    # drifted on every theme addition and never knew host-defined themes.
    html = render_script()

    assert html =~ ~s("phoenix-dark":"dark")
    assert html =~ ~s("phoenix-light":"light")
    # labels come from translated_label_map, not a JS-side title-caser
    assert html =~ ~s("nord":)
  end

  test "system resolves from the CONFIGURED pair, not hardcoded phoenix-*" do
    Application.put_env(:phoenix_kit, :dashboard_themes, ["light", "dark"])

    html = render_script()

    assert html =~ ~s(systemPair = { light: 'light', dark: 'dark' })
  end

  test "runs once per page even if two layouts render it" do
    html = render_script()

    assert html =~ "window.__pkThemeController"
  end

  test "carries every consumer the two deleted copies served" do
    html = render_script()

    # pair toggle contract (theme_controller.ex :toggle mode)
    assert html =~ "themeRole === 'toggle'"
    assert html =~ "themeNext"
    # dropdown option indicators
    assert html =~ "themeRole === 'dropdown-option'"
    assert html =~ "data-theme-active-indicator"
    # admin dropdown open/close a11y
    assert html =~ "data-theme-dropdown"
    assert html =~ "aria-expanded"
    # cross-tab + OS-change + LiveView event listeners
    assert html =~ "addEventListener('storage'"
    assert html =~ "prefers-color-scheme"
    assert html =~ "phx:set-theme"
    # legacy host event, kept for compatibility
    assert html =~ "phx:set-admin-theme"
  end

  test "unknown configured names cannot smuggle script out through the pair" do
    Application.put_env(:phoenix_kit, :dashboard_themes, ["'\"><script>x</script>"])

    html = render_script()

    assert html =~ "systemPair = { light: 'phoenix-light', dark: 'phoenix-dark' }"
    refute html =~ "<script>x</script>"
  end
end
