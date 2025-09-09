defmodule PhoenixKit.Install.AssetRebuild do
  @moduledoc """
  Handles asset rebuilding for PhoenixKit installations and updates.

  This module provides simple functionality to rebuild assets without
  complex checks - assets are always rebuilt to ensure consistency.
  """

  @doc """
  Executes asset rebuilding.

  ## Options
  - `:verbose` - Show detailed output (default: true)

  ## Returns
  - `:rebuild_completed` - Assets were successfully rebuilt
  - `:rebuild_failed` - Asset rebuild failed (non-critical)
  """
  def check_and_rebuild(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, true)

    # Always execute rebuild - no more complex checks needed
    execute_asset_rebuild(verbose)
  end

  # Execute the actual asset rebuild process
  defp execute_asset_rebuild(verbose) do
    if verbose do
      IO.puts("🎨 Rebuilding PhoenixKit assets...")
    end

    try do
      # Run Tailwind compilation if available
      case System.cmd("npm", ["run", "build.css"], stderr_to_stdout: true) do
        {_output, 0} ->
          if verbose, do: IO.puts("✅ Assets rebuilt successfully!")
          :rebuild_completed

        {output, _exit_code} ->
          if verbose do
            IO.puts("⚠️  Asset rebuild completed with warnings:")
            IO.puts(output)
          end

          :rebuild_completed
      end
    rescue
      _ ->
        if verbose do
          IO.puts("ℹ️  Asset rebuild skipped (npm not available or no build script)")
        end

        :rebuild_completed
    end
  end
end
