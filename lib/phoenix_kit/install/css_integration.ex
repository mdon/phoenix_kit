defmodule PhoenixKit.Install.CssIntegration do
  @moduledoc """
  Handles automatic Tailwind CSS + DaisyUI integration for PhoenixKit installation.

  This module provides functionality to:
  - Automatically detect app.css file in Phoenix applications
  - Add PhoenixKit-specific @source and @plugin directives
  - Ensure idempotent operations (safe to run multiple times)
  - Provide fallback instructions if automatic integration fails
  """

  @phoenix_kit_css_marker "/* PhoenixKit Integration - DO NOT REMOVE */"

  @phoenix_kit_integration """
  #{@phoenix_kit_css_marker}
  @source "../../deps/phoenix_kit";
  @plugin "daisyui";
  """

  @doc """
  Automatically integrates PhoenixKit with the parent app's CSS configuration.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with CSS integration applied automatically.
  """
  def add_automatic_css_integration(igniter) do
    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    case find_app_css(css_paths) do
      {:ok, css_path} ->
        integrate_css_automatically(igniter, css_path)

      {:error, :not_found} ->
        add_manual_integration_instructions(igniter)
    end
  end

  @doc """
  Checks what PhoenixKit integration already exists in CSS content.
  Returns a map with detected integrations.
  """
  def check_existing_integration(content) do
    %{
      phoenix_kit_marker: String.contains?(content, @phoenix_kit_css_marker),
      phoenix_kit_source: has_phoenix_kit_source?(content),
      daisyui_plugin: has_daisyui_plugin?(content),
      tailwindcss_import: String.match?(content, ~r/@import\s+["']tailwindcss["']/)
    }
  end

  # Find the main app.css file in common locations
  defp find_app_css(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # Automatically integrate CSS with PhoenixKit requirements
  defp integrate_css_automatically(igniter, css_path) do
    igniter
    |> Igniter.update_file(css_path, &add_smart_integration/1)
    |> add_integration_success_notice(css_path)
  end

  # Smart integration that handles all cases within Igniter context
  def add_smart_integration(source) do
    content = source.content
    existing = check_existing_integration(content)

    cond do
      # Complete integration already exists
      existing.phoenix_kit_source and existing.daisyui_plugin ->
        # No changes needed
        source

      # Partial integration exists, add missing parts
      existing.phoenix_kit_source or existing.daisyui_plugin ->
        add_missing_integration_parts(source, existing)

      # No integration exists, add complete integration
      true ->
        add_complete_integration(source, existing)
    end
  end

  # Generic success notice - we'll determine what was actually done
  defp add_integration_success_notice(igniter, css_path) do
    notice = """

    ✅ PhoenixKit CSS Integration Complete!

    Updated #{css_path} with PhoenixKit integration.
    Your app will now automatically generate all PhoenixKit styles!
    """

    Igniter.add_notice(igniter, notice)
  end

  # Add missing parts to partial integration (source version)
  def add_missing_integration_parts(source, existing) do
    content = source.content
    missing_parts = []

    missing_parts =
      if existing.phoenix_kit_source do
        missing_parts
      else
        [@phoenix_kit_css_marker, "@source \"../../deps/phoenix_kit\";"] ++
          missing_parts
      end

    missing_parts =
      if existing.daisyui_plugin do
        missing_parts
      else
        ["@plugin \"daisyui\";"] ++ missing_parts
      end

    if missing_parts != [] do
      updated_content = insert_missing_parts(content, missing_parts, existing)

      # Use Rewrite.Source.update instead of map update syntax
      Rewrite.Source.update(source, :content, updated_content)
    else
      # No changes needed
      source
    end
  end

  # Add complete PhoenixKit integration (source version)
  defp add_complete_integration(source, _existing) do
    content = source.content

    updated_content =
      case String.split(content, "\n") do
        [_ | _] = lines ->
          insert_phoenix_kit_integration(lines)

        _ ->
          # Empty file, add basic integration
          """
          @import "tailwindcss";
          #{@phoenix_kit_integration}
          """ <> content
      end

    Rewrite.Source.update(source, :content, updated_content)
  end

  # Insert PhoenixKit integration at the end of the file
  defp insert_phoenix_kit_integration(lines) do
    # Check if @import "tailwindcss" exists, if not add it at the beginning
    has_tailwind_import = Enum.any?(lines, &String.match?(&1, ~r/@import\s+["']tailwindcss["']/))

    result_lines =
      if has_tailwind_import do
        # Add PhoenixKit integration at the end
        lines ++ ["", @phoenix_kit_integration]
      else
        # Add tailwindcss import first, then PhoenixKit integration at the end
        ["@import \"tailwindcss\";"] ++ lines ++ ["", @phoenix_kit_integration]
      end

    Enum.join(result_lines, "\n")
  end

  # Helper functions for detecting existing integrations
  defp has_phoenix_kit_source?(content) do
    phoenix_kit_patterns = [
      # Quoted patterns
      ~r/@source\s+["'][^"']*phoenix_kit[^"']*["']/,
      ~r/@source\s+["'][^"']*\.\.\/\.\.\/\.\.\/phoenix_kit[^"']*["']/,
      ~r/@source\s+["'][^"']*\.\/deps\/phoenix_kit[^"']*["']/,
      # Unquoted patterns (without quotes)
      ~r/@source\s+[^;]+phoenix_kit[^;]*;/,
      ~r/@source\s+\.\.\/\.\.\/\.\.\/phoenix_kit[^;]*;/,
      ~r/@source\s+\.\/deps\/phoenix_kit[^;]*;/
    ]

    Enum.any?(phoenix_kit_patterns, &String.match?(content, &1))
  end

  defp has_daisyui_plugin?(content) do
    daisyui_patterns = [
      # Quoted patterns
      ~r/@plugin\s+["']daisyui["']/,
      ~r/@plugin\s+["'][^"']*daisyui[^"']*["']/,
      # Unquoted patterns (with or without options)
      ~r/@plugin\s+[^{;]+daisyui[^{;]*[{;]/,
      ~r/@plugin\s+\.\.\/[^{;]*daisyui[^{;]*[{;]/
    ]

    Enum.any?(daisyui_patterns, &String.match?(content, &1))
  end

  # Insert missing parts into existing CSS content
  defp insert_missing_parts(content, missing_parts, existing) do
    lines = String.split(content, "\n")
    insertion_point = find_insertion_point(lines, existing)
    {before_lines, after_lines} = Enum.split(lines, insertion_point)

    formatted_parts = format_missing_parts(missing_parts, insertion_point)
    new_lines = before_lines ++ formatted_parts ++ after_lines
    Enum.join(new_lines, "\n")
  end

  # Find appropriate location to insert missing parts (at the end)
  defp find_insertion_point(lines, existing) do
    if existing.phoenix_kit_source do
      # Find existing PhoenixKit source line to insert nearby
      find_line_after_pattern(lines, ~r/@source\s+["'][^"']*phoenix_kit[^"']*["']/)
    else
      # Insert at the end of the file
      length(lines)
    end
  end

  # Find line after a regex pattern
  defp find_line_after_pattern(lines, pattern) do
    case Enum.find_index(lines, &String.match?(&1, pattern)) do
      nil -> 0
      index -> index + 1
    end
  end

  # Add missing parts with proper spacing
  defp format_missing_parts(missing_parts, insertion_point) do
    if insertion_point > 0 and length(missing_parts) > 0 do
      [""] ++ missing_parts
    else
      missing_parts
    end
  end

  # Fallback instructions if automatic integration fails
  defp add_manual_integration_instructions(igniter) do
    notice = """

    ⚠️ Could not automatically locate app.css file.

    Please manually add these lines to your CSS file:

    ```css
    @import "tailwindcss";
    @source "../../deps/phoenix_kit";
    @plugin "daisyui";
    ```

    Common locations: assets/css/app.css, priv/static/assets/app.css
    """

    Igniter.add_warning(igniter, notice)
  end
end
