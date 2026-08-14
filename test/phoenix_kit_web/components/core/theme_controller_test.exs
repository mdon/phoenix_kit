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

      assert html =~ ~s(data-theme-role="toggle-option")
      refute html =~ ~s(data-theme-role="dropdown-option")
    end

    test "sun offers the light theme, moon the dark one" do
      html = render_picker(["phoenix-light", "phoenix-dark"])

      assert html =~ "hero-sun"
      assert html =~ "hero-moon"
      assert html =~ ~s(data-theme-target="phoenix-light")
      assert html =~ ~s(data-theme-target="phoenix-dark")
    end

    test "each button dispatches the same phx:set-theme event the dropdown uses" do
      html = render_picker(["light", "dark"])

      assert html =~ "phx:set-theme"
    end
  end

  describe "anything other than a pure pair keeps the dropdown" do
    test "three themes" do
      html = render_picker(["phoenix-light", "phoenix-dark", "nord"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle-option")
    end

    test "a pair plus system — three states need a menu" do
      html = render_picker(["system", "phoenix-light", "phoenix-dark"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle-option")
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
