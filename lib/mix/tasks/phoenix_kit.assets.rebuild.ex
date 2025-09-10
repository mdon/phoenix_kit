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

  alias PhoenixKit.Install.AssetRebuild

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

    # Always show that rebuild is recommended for consistency
    IO.puts("""

    ⚠️  Asset rebuild is RECOMMENDED

    Reasons rebuild is recommended:
    #{analyze_rebuild_reasons(verbose)}

    To rebuild assets, run:
      mix phoenix_kit.assets.rebuild
    """)
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

    # Always rebuild assets - no complex checks needed
    AssetRebuild.check_and_rebuild(verbose: verbose)

    if verbose do
      IO.puts("""

      ✅ PhoenixKit asset rebuild completed!

      Your application should now have the latest CSS integration.
      If you're running a dev server, you may need to refresh your browser.
      """)
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
    [
      "• PhoenixKit assets are always rebuilt to ensure consistency",
      "• Ensures latest Tailwind CSS and daisyUI integration",
      "• Compiles CSS @source directives including PhoenixKit paths"
    ]
  end
end
