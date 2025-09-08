defmodule Mix.Tasks.PhoenixKit.Assets.Rebuild do
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok

  @moduledoc """
  Rebuilds assets for PhoenixKit when CSS configuration changes.

  This task is designed to rebuild assets when PhoenixKit CSS integration
  has been modified or when daisyUI/Tailwind configuration requires updates.

  ## Usage

      $ mix phoenix_kit.assets.rebuild
      $ mix phoenix_kit.assets.rebuild --check
      $ mix phoenix_kit.assets.rebuild --force

  ## Options

    * `--check` - Only check if rebuild is needed, don't execute
    * `--force` - Force rebuild even if not detected as needed
    * `--verbose` - Show detailed output during process (default: true)
    * `--silent` - Suppress all output except errors

  ## When to use

  This task is automatically called by:
  - `mix phoenix_kit.install` (when CSS integration is set up)  
  - `mix phoenix_kit.update` (when version requires asset changes)

  You may need to run it manually when:
  - CSS @source directives were manually modified
  - Tailwind/daisyUI configuration was changed
  - PhoenixKit assets are not displaying correctly

  ## Examples

      # Check if rebuild is needed
      mix phoenix_kit.assets.rebuild --check

      # Force rebuild all assets
      mix phoenix_kit.assets.rebuild --force

      # Silent rebuild (only show errors)
      mix phoenix_kit.assets.rebuild --silent

  ## Integration with CSS

  This task works closely with CSS integration to determine when rebuilds
  are needed based on:
  - Changes in @source "../../deps/phoenix_kit" directives
  - daisyUI plugin configuration
  - PhoenixKit version updates that include CSS changes
  """

  alias PhoenixKit.Install.{AssetRebuild, CssIntegration}

  @shortdoc "Rebuilds PhoenixKit assets when CSS configuration changes"

  @switches [
    check: :boolean,
    force: :boolean,
    verbose: :boolean,
    silent: :boolean
  ]

  @aliases [
    c: :check,
    f: :force,
    v: :verbose,
    s: :silent
  ]

  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    # Determine verbosity
    verbose =
      cond do
        opts[:silent] -> false
        opts[:verbose] -> true
        # Default to verbose
        true -> true
      end

    if opts[:check] do
      perform_check(verbose)
    else
      perform_rebuild(opts[:force] || false, verbose)
    end
  end

  # Perform check-only operation
  defp perform_check(verbose) do
    if verbose do
      IO.puts("""

      🔍 Checking if PhoenixKit asset rebuild is needed...
      """)
    end

    case AssetRebuild.check_and_rebuild(check_only: true, verbose: verbose) do
      :needed ->
        IO.puts("""

        ⚠️  Asset rebuild is NEEDED

        Reasons rebuild is recommended:
        #{analyze_rebuild_reasons(verbose)}

        To rebuild assets, run:
          mix phoenix_kit.assets.rebuild
        """)

      :not_needed ->
        IO.puts("""

        ✅ Asset rebuild is NOT NEEDED

        Your PhoenixKit CSS configuration appears to be up to date.
        #{check_css_integration_status(verbose)}
        """)
    end
  end

  # Perform actual rebuild
  defp perform_rebuild(force, verbose) do
    if verbose do
      IO.puts("""

      🎨 PhoenixKit Asset Rebuild
      """)

      if force do
        IO.puts("Force rebuild enabled - will rebuild regardless of checks")
      end
    end

    case AssetRebuild.check_and_rebuild(force: force, verbose: verbose) do
      :rebuild_completed ->
        if verbose do
          IO.puts("""

          ✅ PhoenixKit assets rebuilt successfully!

          Your application should now have the latest CSS integration.
          If you're running a dev server, you may need to refresh your browser.
          """)
        end

      :rebuild_failed ->
        IO.puts(:stderr, """

        ❌ Asset rebuild failed

        This could be due to:
        - Missing 'mix assets.build' task in your project
        - Tailwind CSS configuration issues
        - Asset compilation errors

        To manually rebuild assets, try:
          mix assets.build
          # or
          cd assets && npm run build
        """)

      :not_needed ->
        if verbose do
          IO.puts("""

          ℹ️  Asset rebuild was not needed

          Your PhoenixKit CSS configuration is already up to date.
          Use --force to rebuild anyway.
          """)
        end
    end
  end

  # Analyze and explain why rebuild is needed
  @spec analyze_rebuild_reasons(boolean()) :: String.t()
  defp analyze_rebuild_reasons(_verbose) do
    reasons = collect_rebuild_reasons()

    if Enum.empty?(reasons) do
      "• General asset compilation recommended for optimal performance"
    else
      Enum.join(reasons, "\n")
    end
  end

  # Helper function to collect rebuild reasons
  @spec collect_rebuild_reasons() :: [String.t()]
  defp collect_rebuild_reasons do
    base_reasons =
      if AssetRebuild.asset_rebuild_needed?(false) do
        [
          "• PhoenixKit contains daisyUI/theme assets that need compilation",
          "• Project uses Tailwind CSS with daisyUI integration",
          "• CSS @source directives include PhoenixKit paths"
        ]
      else
        []
      end

    # Add version-specific reasons
    version_reasons =
      if AssetRebuild.check_version_requires_rebuild(false) do
        ["• Current PhoenixKit version includes CSS changes"]
      else
        []
      end

    base_reasons ++ version_reasons
  end

  # Check CSS integration status for informational purposes
  defp check_css_integration_status(_verbose) do
    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    css_status =
      Enum.find_value(css_paths, fn path ->
        if File.exists?(path) do
          check_file_css_integration(path)
        else
          nil
        end
      end)

    case css_status do
      nil -> "\nNo CSS files found in common locations."
      status -> "\n#{status}"
    end
  rescue
    _ -> "\nCould not analyze CSS integration status."
  end

  # Helper function to check CSS integration in a specific file
  defp check_file_css_integration(path) do
    content = File.read!(path)
    integration_status = CssIntegration.check_existing_integration(content)

    integration_details = []

    integration_details =
      if integration_status.phoenix_kit_source do
        integration_details ++ ["@source directives"]
      else
        integration_details
      end

    integration_details =
      if integration_status.daisyui_plugin do
        integration_details ++ ["daisyUI plugin"]
      else
        integration_details
      end

    if integration_details != [] do
      "Found CSS integration in #{path}: #{Enum.join(integration_details, ", ")}"
    else
      "No PhoenixKit CSS integration found in #{path}"
    end
  end
end
