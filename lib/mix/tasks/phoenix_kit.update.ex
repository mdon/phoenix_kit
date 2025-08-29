defmodule Mix.Tasks.PhoenixKit.Update do
  use Mix.Task

  @moduledoc """
  Updates PhoenixKit to the latest version.

  This task handles updating an existing PhoenixKit installation to the latest version
  by creating upgrade migrations that preserve existing data while adding new features.

  ## Usage

      $ mix phoenix_kit.update
      $ mix phoenix_kit.update --prefix=myapp
      $ mix phoenix_kit.update --status

  ## Options

    * `--prefix` - Database schema prefix (default: "public")
    * `--status` - Show current installation status and available updates
    * `--force` - Force update even if already up to date

  ## Examples

      # Update PhoenixKit to latest version
      mix phoenix_kit.update

      # Check what version is installed and what updates are available
      mix phoenix_kit.update --status

      # Update with custom schema prefix
      mix phoenix_kit.update --prefix=auth

  ## Version Management

  PhoenixKit uses a versioned migration system similar to Oban. Each version
  contains specific database schema changes that can be applied incrementally.

  Current version: V01 (includes basic authentication with role system)

  ## Safe Updates

  All PhoenixKit updates are designed to be:
  - Non-destructive (existing data is preserved)
  - Backward compatible (existing code continues to work)
  - Idempotent (safe to run multiple times)
  - Rollback-capable (can be reverted if needed)
  """

  alias PhoenixKit.Migrations.Postgres

  @shortdoc "Updates PhoenixKit to the latest version"

  @switches [
    prefix: :string,
    status: :boolean,
    force: :boolean
  ]

  @aliases [
    p: :prefix,
    s: :status,
    f: :force
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    if opts[:status] do
      show_status(opts)
    else
      perform_update(opts)
    end
  end

  # Show current installation status and available updates
  defp show_status(opts) do
    prefix = opts[:prefix] || "public"

    case check_installation_status(prefix) do
      {:not_installed} ->
        Mix.shell().info("""

        ❌ PhoenixKit is not installed.

        Please run: mix phoenix_kit.install
        """)

      {:current_version, version} ->
        target_version = Postgres.current_version()

        if version >= target_version do
          Mix.shell().info("""

          ✅ PhoenixKit is up to date!

          Current version: V#{pad_version(version)}
          Latest version: V#{pad_version(target_version)}
          """)
        else
          changes = describe_version_changes(version, target_version)

          Mix.shell().info("""

          📦 PhoenixKit Update Available!

          Current version: V#{pad_version(version)}
          Latest version: V#{pad_version(target_version)}

          What's new:
          #{changes}

          To update, run: mix phoenix_kit.update
          """)
        end
    end
  end

  # Handle not installed scenario
  defp handle_not_installed do
    Mix.shell().error("""

    ❌ PhoenixKit is not installed.

    Please run: mix phoenix_kit.install
    """)
  end

  # Handle update check logic
  defp handle_update_check(prefix, current_version, force) do
    target_version = Postgres.current_version()

    cond do
      current_version >= target_version && !force ->
        handle_already_up_to_date(current_version)

      current_version < target_version || force ->
        handle_update_needed(prefix, current_version, target_version, force)

      true ->
        Mix.shell().info("No update needed.")
    end
  end

  # Handle already up to date scenario
  defp handle_already_up_to_date(current_version) do
    Mix.shell().info("""

    ✅ PhoenixKit is already up to date (V#{pad_version(current_version)}).

    Use --force to regenerate the migration anyway.
    """)
  end

  # Handle update needed scenario
  defp handle_update_needed(prefix, current_version, target_version, force) do
    create_update_migration(prefix, current_version, target_version, force)
    suggest_layout_integration_if_needed()
  end

  # Perform the actual update
  defp perform_update(opts) do
    prefix = opts[:prefix] || "public"
    force = opts[:force] || false

    case check_installation_status(prefix) do
      {:not_installed} ->
        handle_not_installed()

      {:current_version, current_version} ->
        handle_update_check(prefix, current_version, force)
    end
  end

  # Create update migration from current to target version
  defp create_update_migration(prefix, current_version, target_version, force) do
    create_schema = prefix != "public"

    # Ensure migrations directory exists
    migrations_dir = "priv/repo/migrations"
    File.mkdir_p!(migrations_dir)

    # Generate timestamp and migration file name using Ecto format
    timestamp = generate_timestamp()
    action = if force, do: "force_update", else: "update"

    migration_name =
      "#{timestamp}_phoenix_kit_#{action}_v#{pad_version(current_version)}_to_v#{pad_version(target_version)}.exs"

    migration_file = Path.join(migrations_dir, migration_name)

    # Generate module name
    module_name =
      "PhoenixKit#{String.capitalize(action)}V#{pad_version(current_version)}ToV#{pad_version(target_version)}"

    # Create migration content
    migration_content = """
    defmodule Ecto.Migrations.#{module_name} do
      @moduledoc false
      use Ecto.Migration

      def up do
        # PhoenixKit Update Migration: V#{pad_version(current_version)} -> V#{pad_version(target_version)}
        PhoenixKit.Migrations.up([
          prefix: "#{prefix}",
          version: #{target_version},
          create_schema: #{create_schema}
        ])
      end

      def down do
        # Rollback PhoenixKit to V#{pad_version(current_version)}
        PhoenixKit.Migrations.down([
          prefix: "#{prefix}",
          version: #{current_version}
        ])
      end
    end
    """

    # Write migration file
    File.write!(migration_file, migration_content)

    # Show success notice
    changes = describe_version_changes(current_version, target_version)

    notice = """

    📦 PhoenixKit Update Migration Created:
    - Migration: #{migration_name}
    - Updating from V#{pad_version(current_version)} to V#{pad_version(target_version)}

    What's new:
    #{changes}

    Next steps:
      1. Run: mix ecto.migrate
      2. Your PhoenixKit installation will be updated!

    #{if current_version > 0 do
      "Note: This update preserves all existing data and is fully backward compatible."
    else
      ""
    end}
    """

    Mix.shell().info(notice)
  end

  # Check what version of PhoenixKit is currently installed
  defp check_installation_status(prefix) do
    # Use the same version detection logic as the migration system
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}

    try do
      # Use PhoenixKit's centralized runtime version detection function
      current_version = Postgres.migrated_version_runtime(opts)

      if current_version == 0 do
        # Check if migration files exist but haven't been run
        case find_existing_phoenix_kit_migrations() do
          [] -> {:not_installed}
          # Migration files exist but not run
          _migrations -> {:current_version, 0}
        end
      else
        {:current_version, current_version}
      end
    rescue
      _ ->
        # Database error, check migration files as fallback
        case find_existing_phoenix_kit_migrations() do
          [] -> {:not_installed}
          # Migration files exist but DB not accessible
          _migrations -> {:current_version, 0}
        end
    end
  end

  # Find existing PhoenixKit migrations in the project
  defp find_existing_phoenix_kit_migrations do
    if File.exists?("priv/repo/migrations") do
      "priv/repo/migrations"
      |> File.ls!()
      |> Enum.filter(&String.contains?(&1, "phoenix_kit"))
      |> Enum.map(&Path.join("priv/repo/migrations", &1))
    else
      []
    end
  end

  # Describe what changed between versions
  defp describe_version_changes(from_version, to_version) do
    case {from_version, to_version} do
      {0, 1} ->
        "- Complete PhoenixKit installation with authentication and role system"

      {_, _} ->
        "- Various improvements and new features"
    end
  end

  # Generate timestamp in Ecto migration format (same as phoenix_kit.install.ex)
  defp generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  # Pad version number for consistent naming
  defp pad_version(version) when version < 10, do: "0#{version}"
  defp pad_version(version), do: to_string(version)

  # Suggest layout integration if parent app has layouts but PhoenixKit not configured
  defp suggest_layout_integration_if_needed do
    case check_layout_integration_status() do
      :already_configured ->
        # Layout integration already configured, do nothing
        :ok

      {:suggest_integration, layouts_module} ->
        Mix.shell().info("""

        🎨 Layout Integration Available:

        Your app has layouts (#{inspect(layouts_module)}), but PhoenixKit
        is using its default layouts. To match your app's design:

        Add to config/config.exs:
          config :phoenix_kit,
            layout: {#{inspect(layouts_module)}, :app},
            root_layout: {#{inspect(layouts_module)}, :root},  # Optional
            page_title_prefix: "Auth"                          # Optional

        This will make PhoenixKit authentication pages use your app's design.
        """)

      :no_layouts_found ->
        # No parent layouts detected, keep using PhoenixKit defaults
        :ok
    end
  end

  # Check if layout integration should be suggested
  defp check_layout_integration_status do
    # Check if PhoenixKit layout is already configured
    current_layout_config = Application.get_env(:phoenix_kit, :layout)

    case current_layout_config do
      {_module, _template} ->
        # Layout integration already configured
        :already_configured

      _ ->
        # No layout configured, check if parent app has layouts
        case detect_parent_app_layouts() do
          nil -> :no_layouts_found
          layouts_module -> {:suggest_integration, layouts_module}
        end
    end
  end

  # Detect parent app layouts following Phoenix conventions
  defp detect_parent_app_layouts do
    case Mix.Project.get() do
      nil -> nil
      project -> detect_layouts_for_project(project)
    end
  end

  # Detect layouts for a given project
  defp detect_layouts_for_project(project) do
    app_name = project.project()[:app]

    if app_name && app_name != :phoenix_kit do
      try_layout_module_patterns(app_name)
    else
      nil
    end
  end

  # Try different layout module patterns for the app
  defp try_layout_module_patterns(app_name) do
    # Try common Phoenix layout module patterns
    app_web_module = Module.concat([Macro.camelize(to_string(app_name)) <> "Web"])
    layouts_module = Module.concat([app_web_module, "Layouts"])

    if Code.ensure_loaded?(layouts_module) do
      layouts_module
    else
      try_alternative_layout_pattern(app_name)
    end
  end

  # Try alternative layout pattern
  defp try_alternative_layout_pattern(app_name) do
    alt_layouts = Module.concat([Macro.camelize(to_string(app_name)), "Layouts"])

    if Code.ensure_loaded?(alt_layouts) do
      alt_layouts
    else
      nil
    end
  end
end
