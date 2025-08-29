defmodule PhoenixKit.Config do
  @moduledoc """
  Configuration management system for PhoenixKit.

  This module provides a centralized way to manage PhoenixKit configuration,
  supporting both application config and environment-based configuration.

  ## Configuration Sources

  1. **Application Configuration** - Standard Elixir app config
  2. **Environment Variables** - Runtime environment configuration  
  3. **dotenv Files** - Development environment files (optional)

  ## Usage

      # Get all configuration
      config = PhoenixKit.Config.get_all!()
      
      # Get specific values
      repo = PhoenixKit.Config.get!(:repo)
      mailer = PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)
      
      # Import from dotenv (development)
      PhoenixKit.Config.import_from_dotenv()

  ## Configuration Keys

  - `:repo` - Ecto repository module (required)
  - `:mailer` - Mailer module for sending emails
  - `:layout` - Custom layout configuration
  - `:secret_key_base` - Phoenix secret key base
  - `:host` - Application hostname
  - `:port` - Application port

  ## Environment Integration

  The module automatically integrates with `PhoenixKit.ConfigEnv` for 
  environment-based configuration loading.
  """

  alias PhoenixKit.ConfigEnv

  @doc """
  Gets all PhoenixKit configuration.

  Raises an exception if configuration is not loaded.

  ## Examples

      iex> PhoenixKit.Config.get_all!()
      %{repo: MyApp.Repo, mailer: PhoenixKit.Mailer, ...}
  """
  def get_all! do
    case get_all() do
      {:ok, config} ->
        config

      :not_loaded ->
        raise """
        PhoenixKit configuration not loaded.

        Make sure you have configured PhoenixKit in your application:

            # config/config.exs
            config :phoenix_kit,
              repo: YourApp.Repo
              
        Or set environment variables with PHOENIX_KIT_ prefix.

        For development, you can also use:

            PhoenixKit.Config.import_from_dotenv()
        """
    end
  end

  @doc """
  Gets all PhoenixKit configuration.

  Returns `{:ok, config}` or `:not_loaded`.
  """
  def get_all do
    app_config = Application.get_all_env(:phoenix_kit)

    case ConfigEnv.load_config() do
      {:ok, env_config} ->
        # Merge app config with env config, env config takes precedence
        merged_config =
          Map.new(app_config)
          |> Map.merge(env_config)

        {:ok, merged_config}

      :not_loaded ->
        if length(app_config) > 0 do
          {:ok, Map.new(app_config)}
        else
          :not_loaded
        end
    end
  end

  @doc """
  Gets a specific configuration value.

  Raises an exception if the key is not found.

  ## Examples

      iex> PhoenixKit.Config.get!(:repo)
      MyApp.Repo
  """
  def get!(key) do
    case get(key) do
      {:ok, value} ->
        value

      :not_found ->
        raise """
        PhoenixKit configuration key :#{key} not found.

        Available configuration:
        #{inspect_available_config()}

        Make sure to configure :#{key} in your application config:

            config :phoenix_kit, #{key}: YourValue
        """
    end
  end

  @doc """
  Gets a specific configuration value.

  Returns `{:ok, value}` or `:not_found`.
  """
  def get(key) when is_atom(key) do
    case get_all() do
      {:ok, config} ->
        case Map.get(config, key) do
          nil -> :not_found
          value -> {:ok, value}
        end

      :not_loaded ->
        :not_found
    end
  end

  @doc """
  Gets a specific configuration value with a default.

  ## Examples

      iex> PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)
      MyApp.Mailer
      
      iex> PhoenixKit.Config.get(:nonexistent, :default)
      :default
  """
  def get(key, default) when is_atom(key) do
    case get(key) do
      {:ok, value} -> value
      :not_found -> default
    end
  end

  @doc """
  Imports configuration from dotenv files.

  This is useful for development environments where you want to load
  configuration from `.env`, `.env.local`, etc.

  ## Examples

      # Import from default locations
      PhoenixKit.Config.import_from_dotenv()
      
      # Import from specific file  
      PhoenixKit.Config.import_from_dotenv(".env.production")

  ## Supported Files

  - `.env` - Base environment file
  - `.env.local` - Local overrides (gitignored)
  - `.env.development` - Development specific
  - `.env.test` - Test environment specific
  """
  def import_from_dotenv(file_path \\ nil) do
    files_to_try =
      if file_path do
        [file_path]
      else
        [
          ".env",
          ".env.local",
          ".env.development",
          ".env.test"
        ]
      end

    files_to_try
    |> Enum.filter(&File.exists?/1)
    |> Enum.each(&load_dotenv_file/1)

    :ok
  end

  @doc """
  Validates that required configuration is present.

  Raises an exception if any required keys are missing.

  ## Examples

      PhoenixKit.Config.validate_required!([:repo, :secret_key_base])
  """
  def validate_required!(required_keys) do
    config = get_all!()

    missing_keys =
      required_keys
      |> Enum.reject(&Map.has_key?(config, &1))

    if length(missing_keys) > 0 do
      raise """
      Missing required PhoenixKit configuration keys: #{inspect(missing_keys)}

      Current configuration: #{inspect(Map.keys(config))}

      Please add the missing keys to your configuration:

          config :phoenix_kit,
            #{Enum.map_join(missing_keys, ",\n  ", &"#{&1}: YourValue")}
      """
    end

    :ok
  end

  # Load environment variables from a dotenv file
  defp load_dotenv_file(file_path) do
    file_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> Enum.each(&parse_and_set_env_var/1)
  end

  # Parse and set a single environment variable
  defp parse_and_set_env_var(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value) |> String.trim("\"") |> String.trim("'")

        # Only set if not already set (existing env vars take precedence)
        if System.get_env(key) == nil do
          System.put_env(key, value)
        end

      _ ->
        # Skip malformed lines
        :ok
    end
  end

  # Helper to show available configuration for error messages
  defp inspect_available_config do
    case get_all() do
      {:ok, config} ->
        config
        |> Map.keys()
        |> Enum.sort()
        |> inspect()

      :not_loaded ->
        "No configuration loaded"
    end
  end
end
