defmodule PhoenixKit.ThemeDefinitionsTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.ThemeConfig

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :theme_definitions)
      Application.delete_env(:phoenix_kit, :dashboard_themes)
      :persistent_term.erase({ThemeConfig, :theme_variables})
    end)
  end

  defp put_defs(defs), do: Application.put_env(:phoenix_kit, :theme_definitions, defs)

  describe "merging over built-ins" do
    test "a variable override lands in the CSS, the rest of the theme survives" do
      put_defs(%{"phoenix-dark" => %{variables: %{"--color-primary" => "oklch(72% 0.14 158)"}}})

      css = ThemeConfig.custom_theme_css()

      assert css =~ "[data-theme=phoenix-dark]"
      assert css =~ "--color-primary: oklch(72% 0.14 158);"
      # untouched siblings still present
      assert css =~ "--color-base-100"
    end

    test "without config, output is unchanged built-ins" do
      css = ThemeConfig.custom_theme_css()

      assert css =~ "[data-theme=phoenix-light]"
      assert css =~ "oklch(57.38% 0.233 262.08)"
    end
  end

  describe "new named themes" do
    setup do
      put_defs(%{
        "brand-light" => %{
          label: "Brand Light",
          base: :light,
          extends: "phoenix-light",
          variables: %{"--color-primary" => "oklch(48% 0.13 158)"}
        }
      })

      :ok
    end

    test "appear in the CSS with the parent's variables underneath" do
      css = ThemeConfig.custom_theme_css()

      assert css =~ "[data-theme=brand-light]"
      assert css =~ "--color-primary: oklch(48% 0.13 158);"
    end

    test "feed the label, base and picker lookups" do
      assert ThemeConfig.translated_label("brand-light") == "Brand Light"
      assert ThemeConfig.base_map()["brand-light"] == "light"

      Application.put_env(:phoenix_kit, :dashboard_themes, ["brand-light", "phoenix-dark"])

      values =
        ThemeConfig.dropdown_themes(["brand-light", "phoenix-dark"]) |> Enum.map(& &1.value)

      assert values == ["brand-light", "phoenix-dark"]

      # And system resolution uses the host pair.
      assert ThemeConfig.system_pair() == {"brand-light", "phoenix-dark"}
    end
  end

  describe "validation raises, never drops" do
    test "a bad theme name" do
      put_defs(%{"Bad Name!" => %{variables: %{}}})

      assert_raise ArgumentError, ~r/invalid theme name/, fn ->
        ThemeConfig.custom_theme_css()
      end
    end

    test "a non-allowlisted token" do
      put_defs(%{"phoenix-dark" => %{variables: %{"--evil" => "x"}}})

      assert_raise ArgumentError, ~r/not an\s+allowed theme token/s, fn ->
        ThemeConfig.custom_theme_css()
      end
    end

    test "a value that could escape the declaration" do
      # The output is HTML.raw'd into a <style> tag — these are the injection
      # shapes the validator exists to refuse.
      for bad <- ["red; } </style><script>x</script>", "url(javascript:1)", "a /* b */"] do
        put_defs(%{"phoenix-dark" => %{variables: %{"--color-primary" => bad}}})
        :persistent_term.erase({ThemeConfig, :theme_variables})

        assert_raise ArgumentError, ~r/not a single plain CSS value/, fn ->
          ThemeConfig.custom_theme_css()
        end
      end
    end

    test "a new theme without label or base" do
      put_defs(%{"brandless" => %{variables: %{"--color-primary" => "red"}}})

      assert_raise ArgumentError, ~r/needs a :label/, fn ->
        ThemeConfig.custom_theme_css()
      end
    end

    test "extending an unknown theme" do
      put_defs(%{"child" => %{label: "C", base: :dark, extends: "nope", variables: %{}}})

      assert_raise ArgumentError, ~r/extends unknown theme/, fn ->
        ThemeConfig.custom_theme_css()
      end
    end
  end
end
