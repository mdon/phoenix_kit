defmodule PhoenixKitWeb.Components.Core.ThemeControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.ThemeController

  defp render_picker(themes) do
    render_component(&ThemeController.theme_controller/1, themes: themes, id: "t")
  end

  describe "exactly two concrete themes" do
    test "renders a toggle, not a dropdown" do
      html = render_picker(["phoenix-light", "phoenix-dark"])

      assert html =~ ~s(data-theme-role="toggle")
      refute html =~ ~s(data-theme-role="dropdown-option")
    end

    test "one persistent button — activating it never removes the focused element" do
      html = render_picker(["phoenix-light", "phoenix-dark"])

      # The first design hid the active theme's button, which dropped keyboard
      # focus to <body> on every activation. One button, aria-pressed, both
      # icons present with one hidden.
      assert length(String.split(html, "<button")) == 2
      assert html =~ ~s(aria-pressed="false")
      assert html =~ "hero-sun"
      assert html =~ "hero-moon"
      assert html =~ ~s(data-theme-light="phoenix-light")
      assert html =~ ~s(data-theme-dark="phoenix-dark")
      assert html =~ ~s(data-theme-next="phoenix-dark")
    end

    test "order in the config does not decide which half is dark" do
      html = render_picker(["phoenix-dark", "phoenix-light"])

      assert html =~ ~s(data-theme-dark="phoenix-dark")
      assert html =~ ~s(data-theme-light="phoenix-light")
    end
  end

  describe "mode attr" do
    defp render_mode(themes, mode) do
      render_component(&ThemeController.theme_controller/1,
        themes: themes,
        mode: mode,
        id: "t"
      )
    end

    test ":dropdown forces the menu even for a pair" do
      html = render_mode(["phoenix-light", "phoenix-dark"], :dropdown)

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test ":toggle raises unless the list is exactly two concrete themes" do
      assert_raise ArgumentError, ~r/needs exactly two concrete themes/, fn ->
        render_mode(["system", "phoenix-light", "phoenix-dark"], :toggle)
      end
    end

    test ":toggle on a pair renders the toggle" do
      html = render_mode(["phoenix-light", "phoenix-dark"], :toggle)

      assert html =~ ~s(data-theme-role="toggle")
    end
  end

  describe "anything other than a pure pair keeps the dropdown" do
    test "three themes" do
      html = render_picker(["phoenix-light", "phoenix-dark", "nord"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test "a pair plus system — three states need a menu" do
      html = render_picker(["system", "phoenix-light", "phoenix-dark"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test ":all" do
      html = render_picker(:all)

      assert html =~ ~s(data-theme-role="dropdown-option")
    end

    test "a single theme is not a toggle either" do
      html = render_picker(["phoenix-dark"])

      assert html =~ ~s(data-theme-role="dropdown-option")
    end
  end
end
