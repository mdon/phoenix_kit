defmodule PhoenixKit.ThemeConfig do
  @moduledoc """
  Theme configuration utilities for PhoenixKit's DaisyUI integration.

  This module centralises the theme metadata used across the admin UI so that
  PhoenixKit and the consuming application stay in sync. Updating or adding a
  theme requires changing this module and the shared CSS asset only.
  """

  @default_html_theme "phoenix-light"

  @custom_theme_variables %{
    "phoenix-light" => %{
      "color-scheme" => "light",
      "--color-primary" => "oklch(57.38% 0.233 262.08)",
      "--color-primary-content" => "oklch(98% 0.02 262.08)",
      "--color-secondary" => "oklch(75.61% 0.194 333.67)",
      "--color-secondary-content" => "oklch(20% 0.02 333.67)",
      "--color-accent" => "oklch(74.22% 0.209 6.35)",
      "--color-accent-content" => "oklch(20% 0.02 6.35)",
      "--color-neutral" => "oklch(23.04% 0.065 269.31)",
      "--color-neutral-content" => "oklch(98% 0.02 269.31)",
      "--color-base-100" => "oklch(100% 0 0)",
      "--color-base-200" => "oklch(96% 0 0)",
      "--color-base-300" => "oklch(92% 0.005 286.88)",
      "--color-base-content" => "oklch(20% 0.02 269.31)",
      "--color-info" => "oklch(72.06% 0.191 231.6)",
      "--color-info-content" => "oklch(20% 0.02 231.6)",
      "--color-success" => "oklch(64.8% 0.15 160)",
      "--color-success-content" => "oklch(20% 0.02 160)",
      "--color-warning" => "oklch(84.71% 0.199 83.87)",
      "--color-warning-content" => "oklch(20% 0.02 83.87)",
      "--color-error" => "oklch(71.76% 0.221 22.18)",
      "--color-error-content" => "oklch(20% 0.02 22.18)"
    },
    "phoenix-dark" => %{
      "color-scheme" => "dark",
      "--color-primary" => "oklch(57.38% 0.233 262.08)",
      "--color-primary-content" => "oklch(98% 0.02 262.08)",
      "--color-secondary" => "oklch(75.61% 0.194 333.67)",
      "--color-secondary-content" => "oklch(20% 0.02 333.67)",
      "--color-accent" => "oklch(74.22% 0.209 6.35)",
      "--color-accent-content" => "oklch(20% 0.02 6.35)",
      "--color-neutral" => "oklch(32.77% 0.033 264.54)",
      "--color-neutral-content" => "oklch(85% 0.02 264.54)",
      "--color-base-100" => "oklch(25.33% 0.024 265.76)",
      "--color-base-200" => "oklch(23.45% 0.022 265.76)",
      "--color-base-300" => "oklch(21.68% 0.02 265.76)",
      "--color-base-content" => "oklch(85% 0.02 265.76)",
      "--color-info" => "oklch(72.06% 0.191 231.6)",
      "--color-info-content" => "oklch(20% 0.02 231.6)",
      "--color-success" => "oklch(64.8% 0.15 160)",
      "--color-success-content" => "oklch(20% 0.02 160)",
      "--color-warning" => "oklch(84.71% 0.199 83.87)",
      "--color-warning-content" => "oklch(20% 0.02 83.87)",
      "--color-error" => "oklch(71.76% 0.221 22.18)",
      "--color-error-content" => "oklch(20% 0.02 22.18)"
    }
  }

  @labels %{
    "system" => "System",
    "phoenix-light" => "Phoenix Light",
    "phoenix-dark" => "Phoenix Dark",
    "black" => "Black",
    "cupcake" => "Cupcake",
    "synthwave" => "Synthwave",
    "cyberpunk" => "Cyberpunk",
    "forest" => "Forest",
    "dracula" => "Dracula",
    "sunset" => "Sunset",
    "light" => "Light",
    "dark" => "Dark"
  }

  @dropdown_order [
    "system",
    "phoenix-light",
    "phoenix-dark",
    "black",
    "cupcake",
    "synthwave",
    "cyberpunk",
    "forest",
    "dracula",
    "sunset"
  ]

  @preview_themes Map.new(@dropdown_order, fn
                    "system" -> {"system", nil}
                    theme -> {theme, theme}
                  end)

  @base_map %{
    "phoenix-light" => "light",
    "light" => "light",
    "cupcake" => "light",
    "cyberpunk" => "light",
    "phoenix-dark" => "dark",
    "dark" => "dark",
    "black" => "dark",
    "synthwave" => "dark",
    "forest" => "dark",
    "dracula" => "dark",
    "sunset" => "dark"
  }

  @slider_targets %{
    "system" => ["system"],
    "light" => ["light", "phoenix-light", "cupcake", "cyberpunk"],
    "dark" => ["dark", "phoenix-dark", "black", "synthwave", "forest", "dracula", "sunset"]
  }

  @slider_primary %{
    "system" => "system",
    "light" => "phoenix-light",
    "dark" => "phoenix-dark"
  }

  @doc """
  Returns true when the theme system is enabled for PhoenixKit.

  Defaults to true but can be overridden via `config :phoenix_kit, :theme_enabled`.
  """
  def theme_enabled? do
    Application.get_env(:phoenix_kit, :theme_enabled, true)
  end

  @doc """
  Returns the logical default theme name stored in the user's preferences.
  """
  def default_theme, do: "system"

  @doc """
  Returns the initial theme applied to the `<html>` element on first render.
  """
  def default_html_theme, do: @default_html_theme

  @doc """
  Fetches the current theme (alias for `default_theme/0`).
  """
  def get_theme, do: default_theme()

  @doc """
  Returns theme data attributes for HTML elements.
  """
  def theme_data_attributes, do: [{"data-theme", default_html_theme()}]

  @doc """
  Returns modern CSS variables for the theme system.

  Currently unused but kept for backwards compatibility with previous helper
  implementations.
  """
  def modern_css_variables, do: ""

  @doc """
  Returns the ordered list of themes displayed in dropdown selectors.
  """
  def dropdown_themes do
    Enum.map(@dropdown_order, fn theme ->
      %{
        value: theme,
        label: Map.fetch!(@labels, theme),
        preview_theme: Map.get(@preview_themes, theme),
        type: if(theme == "system", do: :system, else: :theme)
      }
    end)
  end

  @doc """
  Returns a map of theme names to user-facing labels.
  """
  def label_map, do: @labels

  @doc """
  Returns a map of theme names to their base variant (`"light"` or `"dark"`).
  """
  def base_map, do: @base_map

  @doc """
  Returns the list of target aliases used by the slider buttons for the given
  group (`"system"`, `"light"`, or `"dark"`).
  """
  def slider_targets(group) when is_binary(group) do
    Map.get(@slider_targets, group, [])
  end

  @doc """
  Returns the slider target configuration map with string keys.
  Suitable for encoding to JSON for client-side usage.
  """
  def slider_target_map, do: @slider_targets

  @doc """
  Returns the canonical theme dispatched when a slider button is pressed.
  """
  def slider_primary_theme(group) when is_binary(group) do
    Map.get(@slider_primary, group, "system")
  end

  @doc """
  Returns the theme slot metadata used by slider buttons.
  """
  def slider_primary_map do
    @slider_primary
  end

  @doc """
  Returns all theme names recognised by PhoenixKit.
  """
  def all_theme_names do
    Map.keys(@labels)
  end

  @doc """
  Returns the raw custom theme variable map.
  """
  def custom_theme_variables, do: @custom_theme_variables

  @doc """
  Returns the custom PhoenixKit theme definitions as a CSS string.

  Only custom PhoenixKit themes are included here; DaisyUI-built themes are
  shipped with the DaisyUI plugin.
  """
  def custom_theme_css do
    @custom_theme_variables
    |> Enum.map_join("\n\n", fn {theme, vars} ->
      variables =
        vars
        |> Enum.map_join("\n", fn {name, value} -> "  #{name}: #{value};" end)

      "[data-theme=#{theme}]\n{\n#{variables}\n}"
    end)
  end
end
