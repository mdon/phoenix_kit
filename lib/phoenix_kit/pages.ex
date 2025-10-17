defmodule PhoenixKit.Pages do
  @moduledoc """
  Pages module for file-based content management.

  Provides filesystem operations for creating, editing, and organizing
  files and folders in a web-based interface.
  """

  alias PhoenixKit.Config

  @doc """
  Checks if Pages module is enabled.

  ## Examples

      iex> PhoenixKit.Pages.enabled?()
      true
  """
  def enabled? do
    PhoenixKit.Settings.get_boolean_setting("pages_enabled", false)
  end

  @doc """
  Enables the Pages module.
  """
  def enable_system do
    PhoenixKit.Settings.update_boolean_setting("pages_enabled", true)
  end

  @doc """
  Disables the Pages module.
  """
  def disable_system do
    PhoenixKit.Settings.update_boolean_setting("pages_enabled", false)
  end

  @doc """
  Gets the root directory path for pages.

  Creates the directory if it doesn't exist.
  Uses the parent application's directory, not PhoenixKit's dependency directory.

  ## Examples

      iex> PhoenixKit.Pages.root_path()
      "/path/to/app/priv/static/pages"
  """
  def root_path do
    # Get parent application's directory reliably
    parent_app = get_parent_app()
    app_root = Application.app_dir(parent_app)
    path = Path.join([app_root, "priv", "static", "pages"])

    require Logger

    Logger.debug(
      "Pages root_path: parent_app=#{inspect(parent_app)}, app_root=#{inspect(app_root)}, path=#{inspect(path)}"
    )

    case File.mkdir_p(path) do
      :ok ->
        path

      {:error, reason} ->
        raise "Failed to create pages directory at #{path}: #{inspect(reason)}"
    end
  end

  # Private Helpers

  defp get_parent_app do
    case Config.get(:repo, nil) do
      nil ->
        # Fallback to phoenix_kit if no repo configured
        :phoenix_kit

      repo_module ->
        # Extract app name from repo module
        # e.g., PhoenixKitTesting.Repo -> :phoenix_kit_testing
        repo_module
        |> Module.split()
        |> List.first()
        |> Macro.underscore()
        |> String.to_atom()
    end
  end
end
