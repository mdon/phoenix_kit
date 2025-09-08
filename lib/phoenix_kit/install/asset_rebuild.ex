defmodule PhoenixKit.Install.AssetRebuild do
  @moduledoc """
  Handles automatic asset rebuilding for PhoenixKit installations and updates.

  This module provides functionality to:
  - Detect when asset rebuilding is needed after migrations
  - Execute asset rebuilding with proper error handling
  - Check for daisyUI and Tailwind CSS integration requirements
  - Provide options for forced and conditional rebuilding
  """

  alias PhoenixKit.Install.{Common, CssIntegration}

  @doc """
  Checks if asset rebuilding is needed and executes it if required.

  This function is called automatically after successful migrations to ensure
  that CSS assets are properly rebuilt when PhoenixKit changes require it.

  ## Options
  - `:force` - Force rebuild even if not detected as needed (default: false)
  - `:check_only` - Only check if rebuild is needed, don't execute (default: false)
  - `:verbose` - Show detailed output (default: true)

  ## Returns
  - `:rebuild_completed` - Assets were successfully rebuilt
  - `:rebuild_failed` - Asset rebuild failed (non-critical)
  - `:not_needed` - Asset rebuild was not needed
  - `:check_only` - Only checked, didn't execute (when check_only: true)
  """
  def check_and_rebuild(opts \\ []) do
    force = Keyword.get(opts, :force, false)
    check_only = Keyword.get(opts, :check_only, false)
    verbose = Keyword.get(opts, :verbose, true)

    rebuild_needed = force || asset_rebuild_needed?(verbose)

    cond do
      check_only ->
        print_check_status(verbose, rebuild_needed)
        if rebuild_needed, do: :needed, else: :not_needed

      rebuild_needed ->
        execute_asset_rebuild(verbose)

      true ->
        print_not_needed_message(verbose)

        :not_needed
    end
  end

  @doc """
  Checks if asset rebuilding is needed based on various criteria.

  This function checks multiple factors:
  - Version changes that require CSS updates
  - Presence of daisyUI assets in PhoenixKit
  - Current project's Tailwind/daisyUI configuration
  - CSS integration status

  ## Parameters
  - `verbose` - Show detailed checking information (default: false)

  ## Returns
  Boolean indicating if asset rebuild is needed.
  """
  @spec asset_rebuild_needed?(boolean()) :: boolean()
  def asset_rebuild_needed?(verbose \\ false) do
    checks = [
      {:phoenix_kit_has_daisy_assets, check_phoenix_kit_daisy_assets(verbose)},
      {:project_uses_tailwind, check_project_tailwind_usage(verbose)},
      {:css_integration_present, check_css_integration(verbose)},
      {:version_requires_rebuild, check_version_requires_rebuild(verbose)}
    ]

    if verbose, do: print_rebuild_checks(checks)

    # Asset rebuild is needed if any of these conditions are true
    Enum.any?(checks, fn {_name, result} -> result end)
  end

  # Helper function to print rebuild check results
  defp print_rebuild_checks(checks) do
    IO.puts("🔍 Asset rebuild checks:")

    Enum.each(checks, fn {check_name, result} ->
      status = if result, do: "✅", else: "❌"
      IO.puts("  #{status} #{format_check_name(check_name)}: #{result}")
    end)
  end

  # Helper function to print check status
  defp print_check_status(verbose, rebuild_needed) do
    if verbose do
      status = if rebuild_needed, do: "NEEDED", else: "NOT NEEDED"
      IO.puts("🎨 Asset rebuild check: #{status}")
    end
  end

  # Helper function to print not needed message
  defp print_not_needed_message(verbose) do
    if verbose do
      IO.puts("✅ Asset rebuild not needed - CSS configuration is up to date")
    end
  end

  @doc """
  Executes the asset rebuild process.

  ## Parameters
  - `verbose` - Show detailed output during rebuild (default: true)

  ## Returns
  - `:rebuild_completed` - Successfully completed
  - `:rebuild_failed` - Failed (non-critical)
  """
  def execute_asset_rebuild(verbose \\ true) do
    if verbose do
      IO.puts("🎨 Starting asset rebuild process...")
    end

    case System.cmd("mix", ["assets.build"], stderr_to_stdout: true) do
      {output, 0} ->
        if verbose do
          IO.puts("✅ Assets rebuilt successfully!")
          IO.puts(output)
        end

        :rebuild_completed

      {output, _exit_code} ->
        if verbose do
          IO.puts("⚠️  Asset rebuild failed (this is optional and non-critical):")
          IO.puts(output)
          IO.puts("💡 You can manually rebuild assets with: mix assets.build")
        end

        :rebuild_failed
    end
  rescue
    error ->
      if verbose do
        IO.puts("⚠️  Asset rebuild execution failed: #{inspect(error)}")
        IO.puts("💡 You can manually rebuild assets with: mix assets.build")
      end

      :rebuild_failed
  end

  @doc """
  Checks for specific version changes that require asset rebuilding.

  This function can be extended to include version-specific rebuild requirements
  based on changelog analysis or migration metadata.

  ## Parameters
  - `verbose` - Show detailed version checking (default: false)

  ## Returns
  Boolean indicating if current version changes require asset rebuild.
  """
  @spec check_version_requires_rebuild(boolean()) :: boolean()
  def check_version_requires_rebuild(verbose \\ false) do
    # For now, we'll consider recent versions that introduced daisyUI changes
    # This can be expanded with migration metadata in the future
    current_version = Common.current_version()

    version_needs_rebuild = current_version >= 3

    if verbose do
      IO.puts("  Version #{current_version} requires rebuild: #{version_needs_rebuild}")
    end

    version_needs_rebuild
  end

  # Private helper functions

  # Check if PhoenixKit itself has daisyUI-related assets
  defp check_phoenix_kit_daisy_assets(verbose) do
    phoenix_kit_assets_path = Path.join(["deps", "phoenix_kit", "priv", "static", "assets"])

    has_daisy_assets =
      if File.dir?(phoenix_kit_assets_path) do
        File.ls!(phoenix_kit_assets_path)
        |> Enum.any?(fn file ->
          String.contains?(file, "daisyui") ||
            String.contains?(file, "theme") ||
            String.contains?(file, "phoenix_kit_daisyui")
        end)
      else
        false
      end

    if verbose do
      IO.puts("  PhoenixKit daisyUI assets found: #{has_daisy_assets}")
    end

    has_daisy_assets
  rescue
    _ ->
      if verbose do
        IO.puts("  PhoenixKit daisyUI assets check failed: false")
      end

      false
  end

  # Check if project uses Tailwind/daisyUI
  defp check_project_tailwind_usage(verbose) do
    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    uses_tailwind =
      Enum.any?(css_paths, fn path ->
        if File.exists?(path) do
          content = File.read!(path)

          String.contains?(content, "tailwindcss") ||
            String.contains?(content, "daisyui") ||
            String.contains?(content, "@plugin")
        else
          false
        end
      end)

    if verbose do
      IO.puts("  Project uses Tailwind/daisyUI: #{uses_tailwind}")
    end

    uses_tailwind
  rescue
    _ ->
      if verbose do
        IO.puts("  Tailwind usage check failed: false")
      end

      false
  end

  # Check if CSS integration is properly configured
  defp check_css_integration(verbose) do
    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    has_integration =
      Enum.any?(css_paths, fn path ->
        if File.exists?(path) do
          content = File.read!(path)
          integration_status = CssIntegration.check_existing_integration(content)

          # Has PhoenixKit source integration
          integration_status.phoenix_kit_source || integration_status.phoenix_kit_marker
        else
          false
        end
      end)

    if verbose do
      IO.puts("  PhoenixKit CSS integration found: #{has_integration}")
    end

    has_integration
  rescue
    _ ->
      if verbose do
        IO.puts("  CSS integration check failed: false")
      end

      false
  end

  # Format check name for display
  defp format_check_name(:phoenix_kit_has_daisy_assets), do: "PhoenixKit has daisyUI assets"
  defp format_check_name(:project_uses_tailwind), do: "Project uses Tailwind/daisyUI"
  defp format_check_name(:css_integration_present), do: "CSS integration present"
  defp format_check_name(:version_requires_rebuild), do: "Version requires rebuild"
  defp format_check_name(name), do: to_string(name)
end
