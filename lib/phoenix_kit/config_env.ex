defmodule PhoenixKit.ConfigEnv do
  @moduledoc """
  Environment-based configuration loader for PhoenixKit.

  This module provides functionality to load configuration from environment variables
  and parent application settings, supporting common deployment patterns.

  ## Usage

      case PhoenixKit.ConfigEnv.load_config() do
        {:ok, config} -> 
          # Use loaded configuration
          config
          
        :not_loaded ->
          # Fallback to defaults or raise error
          raise "Configuration not loaded"
      end

  ## Environment Variables

  The module automatically detects and loads common environment variables:

  - `DATABASE_URL` - Database connection string
  - `SECRET_KEY_BASE` - Phoenix secret key base  
  - `PHX_HOST` - Application hostname
  - `PORT` - Application port
  - Custom PhoenixKit variables with `PHOENIX_KIT_` prefix

  ## Integration

  This module integrates with the parent application's configuration system,
  automatically detecting available configuration sources.
  """

  @doc """
  Loads configuration from environment and parent application.

  Returns `{:ok, config}` if configuration is successfully loaded,
  or `:not_loaded` if no configuration sources are available.

  ## Examples

      iex> PhoenixKit.ConfigEnv.load_config()
      {:ok, %{database_url: "postgres://...", secret_key_base: "..."}}
      
      iex> PhoenixKit.ConfigEnv.load_config()
      :not_loaded
  """
  def load_config do
    config = %{}

    config
    |> load_database_config()
    |> load_phoenix_config()
    |> load_phoenix_kit_config()
    |> case do
      config when map_size(config) > 0 ->
        {:ok, config}

      _empty ->
        :not_loaded
    end
  end

  @doc """
  Gets a specific configuration value by key.

  Returns `{:ok, value}` if the key exists, `:not_found` otherwise.

  ## Examples

      iex> PhoenixKit.ConfigEnv.get_config(:database_url)
      {:ok, "postgres://localhost/myapp"}
      
      iex> PhoenixKit.ConfigEnv.get_config(:nonexistent)
      :not_found
  """
  def get_config(key) do
    case load_config() do
      {:ok, config} ->
        case Map.get(config, key) do
          nil -> :not_found
          value -> {:ok, value}
        end

      :not_loaded ->
        :not_found
    end
  end

  # Load database-related configuration
  defp load_database_config(config) do
    config
    |> maybe_put(:database_url, System.get_env("DATABASE_URL"))
    |> maybe_put(:repo, detect_repo())
  end

  # Load Phoenix application configuration
  defp load_phoenix_config(config) do
    config
    |> maybe_put(:secret_key_base, System.get_env("SECRET_KEY_BASE"))
    |> maybe_put(:host, System.get_env("PHX_HOST") || System.get_env("HOST"))
    |> maybe_put(:port, parse_port(System.get_env("PORT")))
  end

  # Load PhoenixKit specific configuration
  defp load_phoenix_kit_config(config) do
    System.get_env()
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "PHOENIX_KIT_") end)
    |> Enum.reduce(config, fn {key, value}, acc ->
      config_key =
        key
        |> String.replace_prefix("PHOENIX_KIT_", "")
        |> String.downcase()
        |> String.to_atom()

      Map.put(acc, config_key, value)
    end)
  end

  # Extract repository from application's ecto_repos configuration
  defp extract_repo_from_app({app, _description, _version}) do
    case Application.get_env(app, :ecto_repos) do
      [repo | _] -> repo
      _ -> nil
    end
  end

  # Auto-detect Ecto repository from application configuration
  defp detect_repo do
    case Application.get_env(:phoenix_kit, :repo) do
      nil ->
        # Try to detect from common patterns
        Application.loaded_applications()
        |> Enum.find_value(&extract_repo_from_app/1)

      configured_repo ->
        configured_repo
    end
  end

  # Parse port string to integer
  defp parse_port(nil), do: nil

  defp parse_port(port_string) when is_binary(port_string) do
    case Integer.parse(port_string) do
      {port, ""} when port > 0 and port <= 65_535 -> port
      _ -> nil
    end
  end

  # Helper to conditionally put values in map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
