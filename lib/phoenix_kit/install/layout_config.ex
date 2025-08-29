defmodule PhoenixKit.Install.LayoutConfig do
  @moduledoc """
  Handles layout integration configuration for PhoenixKit installation.

  This module provides functionality to:
  - Detect app layouts using Phoenix conventions
  - Add layout configuration to config files
  - Handle recompilation requirements
  - Generate appropriate notices for layout setup
  """

  alias Igniter.Project.{Application, Config}
  alias Igniter.Project.Module, as: IgniterModule

  alias PhoenixKit.Utils.PhoenixVersion

  @doc """
  Adds layout integration configuration to the Phoenix application.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with layout configuration and notices.
  """
  def add_layout_integration_configuration(igniter) do
    case detect_app_layouts(igniter) do
      {igniter, nil} ->
        # No layouts detected, use PhoenixKit defaults
        add_layout_integration_notice(igniter, :no_layouts_detected)

      {igniter, {layouts_module, _}} ->
        # Add layout configuration to config.exs
        igniter
        |> add_layout_config(layouts_module)
        |> add_layout_integration_notice(:layouts_detected)
    end
  end

  # Detect app layouts using IgniterPhoenix
  defp detect_app_layouts(igniter) do
    case Application.app_name(igniter) do
      nil -> {igniter, nil}
      app_name -> detect_layouts_for_app(igniter, app_name)
    end
  end

  # Try to detect layouts module following Phoenix conventions
  defp detect_layouts_for_app(igniter, app_name) do
    app_web_module = Module.concat([Macro.camelize(to_string(app_name)) <> "Web"])
    layouts_module = Module.concat([app_web_module, "Layouts"])

    case IgniterModule.module_exists(igniter, layouts_module) do
      {true, igniter} ->
        {igniter, {layouts_module, :app}}

      {false, igniter} ->
        try_alternative_layouts_pattern(igniter, app_name)
    end
  end

  # Try alternative patterns like MyApp.Layouts
  defp try_alternative_layouts_pattern(igniter, app_name) do
    alt_layouts_module = Module.concat([Macro.camelize(to_string(app_name)), "Layouts"])

    case IgniterModule.module_exists(igniter, alt_layouts_module) do
      {true, igniter} -> {igniter, {alt_layouts_module, :app}}
      {false, igniter} -> {igniter, nil}
    end
  end

  # Add layout configuration to config.exs with Phoenix version support
  defp add_layout_config(igniter, layouts_module) do
    # Add modern layout configuration based on Phoenix version
    igniter
    |> add_modern_layout_config_with_comments(layouts_module)
    |> recompile_phoenix_kit_dependency()
  end

  # Add modern layout configuration with Phoenix version detection and comments
  defp add_modern_layout_config_with_comments(igniter, layouts_module) do
    case PhoenixVersion.get_strategy() do
      :modern ->
        # Phoenix v1.8+ - Use function component configuration
        add_modern_layout_config(igniter, layouts_module)

      :legacy ->
        # Phoenix v1.7- - Use legacy layout configuration
        add_legacy_layout_config(igniter, layouts_module)
    end
    |> add_version_aware_comments(layouts_module)
  end

  # Skip redundant layout notice since already covered
  defp add_layout_integration_notice(igniter, :layouts_detected) do
    igniter
  end

  defp add_layout_integration_notice(igniter, :no_layouts_detected) do
    notice = "💡 To integrate with your app's design, see layout configuration in README.md"
    Igniter.add_notice(igniter, notice)
  end

  # Recompile PhoenixKit dependency to pick up layout configuration changes
  defp recompile_phoenix_kit_dependency(igniter) do
    # Since this is running during installation, we need to recompile the dependency
    # to ensure the layout configuration changes are picked up immediately
    recompile_notice = """

    🔄 Recompiling PhoenixKit to apply layout configuration...
    """

    igniter = Igniter.add_notice(igniter, recompile_notice)

    # Run the recompilation in the background using System.cmd instead of Mix task
    # to avoid potential issues with Mix state during Igniter execution
    try do
      {output, exit_code} =
        System.cmd("mix", ["deps.compile", "phoenix_kit", "--force"], stderr_to_stdout: true)

      if exit_code == 0 do
        success_notice = "✅ PhoenixKit dependency recompiled successfully!"
        Igniter.add_notice(igniter, success_notice)
      else
        warning_notice =
          "⚠️ Could not automatically recompile PhoenixKit dependency. Output: #{String.slice(output, 0, 200)}"

        Igniter.add_warning(igniter, warning_notice)
      end
    rescue
      _ ->
        warning_notice =
          "⚠️ Could not automatically recompile PhoenixKit dependency. Please run: mix deps.compile phoenix_kit --force"

        Igniter.add_warning(igniter, warning_notice)
    end
  end

  # Phoenix v1.8+ layout configuration - uses function components, no router-level config needed
  defp add_modern_layout_config(igniter, layouts_module) do
    igniter
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:layouts_module],
      layouts_module
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:phoenix_version_strategy],
      :modern
    )
  end

  # Phoenix v1.7- legacy layout configuration
  defp add_legacy_layout_config(igniter, layouts_module) do
    igniter
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:layout],
      {layouts_module, :app}
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:root_layout],
      {layouts_module, :root}
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:phoenix_version_strategy],
      :legacy
    )
  end

  # Add version-aware comments to configuration
  defp add_version_aware_comments(igniter, layouts_module) do
    phoenix_version = PhoenixVersion.get_version()
    strategy = PhoenixVersion.get_strategy()

    # Add an informational notice about Phoenix version and strategy
    version_notice = """
    PhoenixKit Layout Integration Configuration:

    • Phoenix Version: #{phoenix_version} (Strategy: #{strategy})
    • LayoutWrapper will automatically detect your Phoenix version
    • Phoenix v1.8+: Uses function component layouts with dynamic calling
    • Phoenix v1.7-: Uses legacy router-level layout configuration

    Configuration allows PhoenixKit to integrate seamlessly with your app's layouts
    while maintaining full backward compatibility.
    """

    igniter
    |> Igniter.add_notice(version_notice)
    |> add_integration_instructions(layouts_module, strategy)
  end

  # Add integration instructions based on Phoenix version
  defp add_integration_instructions(igniter, layouts_module, strategy) do
    case strategy do
      :modern ->
        add_modern_integration_instructions(igniter, layouts_module)

      :legacy ->
        add_legacy_integration_instructions(igniter, layouts_module)
    end
  end

  # Phoenix v1.8+ integration instructions
  defp add_modern_integration_instructions(igniter, layouts_module) do
    instructions = """

    Phoenix v1.8+ Integration Instructions:

    1. Your layouts (#{layouts_module}) will be called as function components
    2. PhoenixKit templates now use LayoutWrapper for seamless integration
    3. No additional changes needed - the wrapper handles version detection

    For manual integration in your own templates:

        <#{layouts_module}.app flash={@flash}>
          <!-- Your content here -->
        </#{layouts_module}.app>
    """

    Igniter.add_notice(igniter, instructions)
  end

  # Phoenix v1.7- integration instructions
  defp add_legacy_integration_instructions(igniter, layouts_module) do
    instructions = """

    Phoenix v1.7- Integration Instructions:

    1. Your layouts (#{layouts_module}) are configured at router level
    2. PhoenixKit templates use LayoutWrapper with legacy mode detection
    3. Layout configuration added to config.exs automatically

    The layout wrapper will detect legacy mode and render content appropriately.
    """

    Igniter.add_notice(igniter, instructions)
  end
end
