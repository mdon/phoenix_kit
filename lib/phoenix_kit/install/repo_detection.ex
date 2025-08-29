defmodule PhoenixKit.Install.RepoDetection do
  @moduledoc """
  Handles repository detection and validation for PhoenixKit installation.

  This module provides functionality to:
  - Auto-detect Ecto repositories from various sources
  - Validate PostgreSQL adapter usage
  - Handle custom repository specifications
  """

  alias Igniter.Libs.Ecto
  alias Igniter.Project.Module, as: IgniterModule

  @doc """
  Adds PhoenixKit configuration with detected or specified repository.

  ## Parameters
  - `igniter` - The igniter context
  - `custom_repo` - Custom repository module (optional)

  ## Returns
  Updated igniter with repository configuration or warning if not found.
  """
  def add_phoenix_kit_configuration(igniter, custom_repo) do
    case find_or_detect_repo(igniter, custom_repo) do
      {igniter, nil} ->
        warning = create_repo_not_found_warning()
        Igniter.add_warning(igniter, warning)

      {igniter, repo_module} ->
        {updated_igniter, _} = validate_postgresql_adapter(igniter, repo_module)
        add_repo_config_to_files(updated_igniter, repo_module)
    end
  end

  # Find specified repo or auto-detect from project
  defp find_or_detect_repo(igniter, nil) do
    # Try multiple methods to find repos
    with {igniter, nil} <- try_igniter_ecto_list(igniter),
         {igniter, nil} <- try_application_config(igniter) do
      try_naming_patterns(igniter)
    end
  end

  defp find_or_detect_repo(igniter, repo_string) when is_binary(repo_string) do
    repo_module = Module.concat([repo_string])

    case IgniterModule.module_exists(igniter, repo_module) do
      {true, igniter} ->
        validate_postgres_adapter(igniter, repo_module)

      {false, igniter} ->
        Igniter.add_warning(igniter, "Specified repo #{repo_string} does not exist")
        {igniter, nil}
    end
  end

  # Method 1: Use Igniter's Ecto lib
  defp try_igniter_ecto_list(igniter) do
    case Ecto.list_repos(igniter) do
      {igniter, [repo | _]} -> validate_postgres_adapter(igniter, repo)
      {igniter, []} -> {igniter, nil}
    end
  end

  # Method 2: Try Application config directly
  defp try_application_config(igniter) do
    parent_app_name = Mix.Project.config()[:app]

    case Elixir.Application.get_env(parent_app_name, :ecto_repos, []) do
      [repo | _] -> validate_postgres_adapter(igniter, repo)
      [] -> {igniter, nil}
    end
  rescue
    _ -> {igniter, nil}
  end

  # Method 3: Try common naming patterns
  defp try_naming_patterns(igniter) do
    parent_app_name = Mix.Project.config()[:app]

    case parent_app_name do
      nil ->
        {igniter, nil}

      app_name ->
        # Try most common pattern: AppName.Repo
        repo_module = Module.concat([Macro.camelize(to_string(app_name)), "Repo"])

        case IgniterModule.module_exists(igniter, repo_module) do
          {true, igniter} -> validate_postgres_adapter(igniter, repo_module)
          {false, igniter} -> {igniter, nil}
        end
    end
  rescue
    _ -> {igniter, nil}
  end

  # Validate that the repo uses PostgreSQL adapter
  defp validate_postgresql_adapter(igniter, repo_module) do
    # Check if module is loaded and has __adapter__ function
    if Code.ensure_loaded?(repo_module) and function_exported?(repo_module, :__adapter__, 0) do
      case repo_module.__adapter__() do
        Ecto.Adapters.Postgres ->
          # PostgreSQL detected - add informational notice
          notice = """

          ✅ PostgreSQL adapter detected (#{inspect(repo_module)})
          """

          Igniter.add_notice(igniter, notice)

        other_adapter ->
          # Non-PostgreSQL adapter - add warning but continue
          warning = """
          ⚠️  PhoenixKit is optimized for PostgreSQL (Ecto.Adapters.Postgres)
          Current adapter: #{inspect(other_adapter)}

          Some features may not work as expected with other databases.
          Consider switching to PostgreSQL for the best experience.
          """

          Igniter.add_warning(igniter, warning)
      end
    else
      # Cannot determine adapter - add notice
      notice = """

      💡 Cannot determine database adapter at install time.
      PhoenixKit is optimized for PostgreSQL (Ecto.Adapters.Postgres).
      """

      Igniter.add_notice(igniter, notice)
    end

    {igniter, repo_module}
  rescue
    _ ->
      # Error checking adapter - just continue silently
      {igniter, repo_module}
  end

  # Alternative validate function for when we just want to trust detection
  defp validate_postgres_adapter(igniter, repo_module) do
    # Trust Igniter's detection - no need for verbose notices
    {igniter, repo_module}
  end

  # Add repo configuration to config files
  defp add_repo_config_to_files(igniter, repo_module) do
    alias Igniter.Project.Config

    igniter
    # Add repo config to main config.exs
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:repo],
      repo_module
    )
    # Also add repo config to test.exs for testing
    |> Config.configure_new(
      "test.exs",
      :phoenix_kit,
      [:repo],
      repo_module
    )
  end

  # Create warning message when repository cannot be found
  defp create_repo_not_found_warning do
    """
    Could not determine application name or find Ecto repo automatically.

    Please specify with --repo option:

      mix phoenix_kit.install --repo YourApp.Repo

    Common repo names:
      - MyAppRepo, MyApp.Repo

    Or manually add to config/config.exs:

      config :phoenix_kit, repo: YourApp.Repo
    """
  end
end
