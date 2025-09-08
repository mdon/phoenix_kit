defmodule Mix.Tasks.PhoenixKit.Status do
  @moduledoc """
  Shows comprehensive status of PhoenixKit installation.

  This task provides a detailed overview of your PhoenixKit installation status,
  including version information, database connectivity, assets status, and
  suggested next actions.

  ## Usage

      $ mix phoenix_kit.status
      $ mix phoenix_kit.status --prefix=myapp

  ## Options

    * `--prefix` - Database schema prefix (default: "public")
    * `--verbose` - Show detailed diagnostic information

  ## Examples

      # Show status for default installation
      mix phoenix_kit.status

      # Show status for custom schema prefix
      mix phoenix_kit.status --prefix=auth

      # Show detailed diagnostic information
      mix phoenix_kit.status --verbose

  ## Sample Output

      PhoenixKit v1.2.1
      ├── Installed: V03 ✅
      ├── Database: Connected ✅  
      ├── Assets: Built ✅
      └── Status: Ready to use

  """

  use Mix.Task
  alias Ecto.Adapters.SQL
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Install.{AssetRebuild, Common}

  @impl Mix.Task
  @spec run([String.t()]) :: :ok

  @shortdoc "Shows comprehensive PhoenixKit installation status"

  @switches [
    prefix: :string,
    verbose: :boolean
  ]

  @aliases [
    p: :prefix,
    v: :verbose
  ]

  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    prefix = opts[:prefix] || "public"
    verbose = opts[:verbose] || false

    show_comprehensive_status(prefix, verbose)
  end

  # Main status display function
  defp show_comprehensive_status(prefix, verbose) do
    # Get all status information
    phoenix_kit_version = get_phoenix_kit_version()
    installation_status = get_installation_status(prefix)
    database_status = get_database_status(prefix)
    assets_status = get_assets_status()
    next_action = determine_next_action(installation_status, prefix)

    # Display header
    IO.puts("\n#{IO.ANSI.bright()}PhoenixKit v#{phoenix_kit_version}#{IO.ANSI.reset()}")

    # Display status tree
    display_status_tree([
      {"Installed", format_installation_status(installation_status)},
      {"Database", format_database_status(database_status)},
      {"Assets", format_assets_status(assets_status)},
      {"Next", format_next_action(next_action)}
    ])

    # Show verbose information if requested
    if verbose do
      show_verbose_diagnostics(prefix, installation_status, database_status, assets_status)
    end

    IO.puts("")
  end

  # Get PhoenixKit module version
  defp get_phoenix_kit_version do
    case :application.get_key(:phoenix_kit, :vsn) do
      {:ok, vsn} when is_list(vsn) -> List.to_string(vsn)
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "unknown"
    end
  end

  # Get installation status
  defp get_installation_status(prefix) do
    case Common.check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:current_version, version} ->
        target_version = Postgres.current_version()

        if version >= target_version do
          {:up_to_date, version}
        else
          {:needs_update, version, target_version}
        end
    end
  end

  # Get database connectivity status
  defp get_database_status(prefix) do
    repo = Application.get_env(:phoenix_kit, :repo)

    if repo do
      # Test database connection with a simple query
      case SQL.query(repo, "SELECT 1", []) do
        {:ok, _result} ->
          check_phoenix_kit_tables(prefix)

        {:error, reason} ->
          {:connection_error, reason}
      end
    else
      {:no_repo_configured}
    end
  rescue
    error -> {:error, error}
  end

  # Helper function to check if PhoenixKit tables exist
  defp check_phoenix_kit_tables(prefix) do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    version = Postgres.migrated_version_runtime(opts)

    if version > 0 do
      {:connected_with_tables, version}
    else
      {:connected_no_tables}
    end
  end

  # Get assets build status
  defp get_assets_status do
    cond do
      AssetRebuild.asset_rebuild_needed?(false) ->
        {:needs_rebuild}

      File.exists?("priv/static/assets/app.css") || File.exists?("priv/static/css/app.css") ->
        {:built}

      true ->
        {:not_built}
    end
  end

  # Determine next recommended action
  defp determine_next_action({:not_installed}, _prefix) do
    {:install, "mix phoenix_kit.install"}
  end

  defp determine_next_action({:needs_update, _current, _target}, prefix) do
    cmd =
      if prefix != "public",
        do: "mix phoenix_kit.update --prefix=#{prefix}",
        else: "mix phoenix_kit.update"

    {:update, cmd}
  end

  defp determine_next_action({:up_to_date, _version}, _prefix) do
    {:ready, "Ready to use"}
  end

  # Format installation status for display
  defp format_installation_status({:not_installed}) do
    "#{IO.ANSI.red()}Not installed#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:up_to_date, version}) do
    "#{IO.ANSI.green()}V#{pad_version(version)} ✅#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:needs_update, current, target}) do
    "#{IO.ANSI.yellow()}V#{pad_version(current)} (needs update to V#{pad_version(target)})#{IO.ANSI.reset()}"
  end

  # Format database status for display
  defp format_database_status({:connected_with_tables, _version}) do
    "#{IO.ANSI.green()}Connected ✅#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connected_no_tables}) do
    "#{IO.ANSI.yellow()}Connected (no tables)#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connection_error, _reason}) do
    "#{IO.ANSI.red()}Connection failed ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:no_repo_configured}) do
    "#{IO.ANSI.red()}No repo configured ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:error, _error}) do
    "#{IO.ANSI.red()}Error ❌#{IO.ANSI.reset()}"
  end

  # Format assets status for display
  defp format_assets_status({:built}) do
    "#{IO.ANSI.green()}Built ✅#{IO.ANSI.reset()}"
  end

  defp format_assets_status({:needs_rebuild}) do
    "#{IO.ANSI.yellow()}Needs rebuild#{IO.ANSI.reset()}"
  end

  defp format_assets_status({:not_built}) do
    "#{IO.ANSI.yellow()}Not built#{IO.ANSI.reset()}"
  end

  # Format next action for display
  defp format_next_action({:install, command}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:update, command}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:ready, message}) do
    "#{IO.ANSI.green()}#{message}#{IO.ANSI.reset()}"
  end

  # Display status information in tree format
  defp display_status_tree(items) do
    items
    |> Enum.with_index()
    |> Enum.each(fn {{label, value}, index} ->
      is_last = index == length(items) - 1
      prefix = if is_last, do: "└── ", else: "├── "

      IO.puts("#{prefix}#{IO.ANSI.bright()}#{label}#{IO.ANSI.reset()}: #{value}")
    end)
  end

  # Show detailed diagnostic information
  defp show_verbose_diagnostics(prefix, installation_status, database_status, assets_status) do
    IO.puts("\n#{IO.ANSI.bright()}═══ Detailed Diagnostics ═══#{IO.ANSI.reset()}")

    show_installation_diagnostics(installation_status, prefix)
    show_database_diagnostics(database_status, prefix)
    show_assets_diagnostics(assets_status)
    show_configuration_diagnostics()
  end

  # Show installation diagnostics
  defp show_installation_diagnostics(status, prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Installation:#{IO.ANSI.reset()}")
    IO.puts("  Schema prefix: #{prefix}")

    case status do
      {:not_installed} ->
        IO.puts("  Migration files: #{inspect(Common.find_existing_phoenix_kit_migrations())}")

      {:up_to_date, version} ->
        IO.puts("  Current version: V#{pad_version(version)}")
        IO.puts("  Target version: V#{pad_version(Postgres.current_version())}")

      {:needs_update, current, target} ->
        IO.puts("  Current version: V#{pad_version(current)}")
        IO.puts("  Target version: V#{pad_version(target)}")
        changes = Common.describe_version_changes(current, target)
        IO.puts("  Available changes:")
        String.split(changes, "\n") |> Enum.each(&IO.puts("    #{&1}"))
    end
  end

  # Show database diagnostics
  defp show_database_diagnostics(status, _prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Database:#{IO.ANSI.reset()}")
    repo = Application.get_env(:phoenix_kit, :repo)
    IO.puts("  Configured repo: #{inspect(repo)}")

    case status do
      {:connected_with_tables, version} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Present (V#{pad_version(version)})")

      {:connected_no_tables} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Missing")

      {:connection_error, reason} ->
        IO.puts("  Connection: Failed")
        IO.puts("  Error: #{inspect(reason)}")

      {:no_repo_configured} ->
        IO.puts("  Connection: No repo configured")

      {:error, error} ->
        IO.puts("  Connection: Error")
        IO.puts("  Details: #{inspect(error)}")
    end
  end

  # Show assets diagnostics
  defp show_assets_diagnostics(status) do
    IO.puts("\n#{IO.ANSI.bright()}Assets:#{IO.ANSI.reset()}")

    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "priv/static/css/app.css"
    ]

    existing_css = Enum.filter(css_paths, &File.exists?/1)
    IO.puts("  CSS files found: #{inspect(existing_css)}")

    case status do
      {:built} ->
        IO.puts("  Status: Built and up to date")

      {:needs_rebuild} ->
        IO.puts("  Status: Needs rebuild")
        IO.puts("  Reason: PhoenixKit assets have been updated")

      {:not_built} ->
        IO.puts("  Status: Not built or not found")
    end
  end

  # Show configuration diagnostics
  defp show_configuration_diagnostics do
    IO.puts("\n#{IO.ANSI.bright()}Configuration:#{IO.ANSI.reset()}")

    # Check layout configuration
    layout_config = Application.get_env(:phoenix_kit, :layout)
    IO.puts("  Layout integration: #{if layout_config, do: "Configured", else: "Using defaults"}")

    # Check theme configuration
    theme_config = Application.get_env(:phoenix_kit, :theme_enabled, false)
    IO.puts("  Theme system: #{if theme_config, do: "Enabled", else: "Disabled"}")

    # Check mailer configuration
    mailer_config = Application.get_env(:phoenix_kit, PhoenixKit.Mailer)
    IO.puts("  Mailer: #{if mailer_config, do: "Configured", else: "Not configured"}")
  end

  # Pad version number for consistent display
  defp pad_version(version) when version < 10, do: "0#{version}"
  defp pad_version(version), do: to_string(version)
end
