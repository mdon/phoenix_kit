defmodule PhoenixKit.MultiLanguage do
  @moduledoc """
  Multi Language system for PhoenixKit - complete management in a single module.

  This module provides management for multi-language support in PhoenixKit applications.
  It handles language configuration, system settings, and language data through JSON settings.

  ## Language Structure

  Each language has the following structure:
  - `code`: Language code (e.g., "en", "es", "fr")
  - `name`: Full language name (e.g., "English", "Spanish", "French")
  - `is_default`: Boolean indicating if this is the default language
  - `is_enabled`: Boolean indicating if this language is active
  - `position`: Integer for display ordering (1, 2, 3, etc.)

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if multi-language system is enabled
  - `enable_system/0` - Enable the multi-language system with default English
  - `disable_system/0` - Disable the multi-language system
  - `get_config/0` - Get complete system configuration

  ### Language Management
  - `get_languages/0` - Get all configured languages
  - `get_enabled_languages/0` - Get only enabled languages
  - `get_default_language/0` - Get the default language
  - `add_language/1` - Add a new language to the system
  - `update_language/2` - Update an existing language
  - `remove_language/1` - Remove a language from the system
  - `set_default_language/1` - Set a new default language
  - `enable_language/1` - Enable a specific language
  - `disable_language/1` - Disable a specific language

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.MultiLanguage.enabled?() do
        # Multi-language system is active
      end

      # Enable system (creates default English language)
      {:ok, config} = PhoenixKit.MultiLanguage.enable_system()

      # Add a new language
      {:ok, config} = PhoenixKit.MultiLanguage.add_language(%{
        code: "es",
        name: "Spanish",
        is_enabled: true
      })

      # Get all languages
      languages = PhoenixKit.MultiLanguage.get_languages()
      # => [%{code: "en", name: "English", is_default: true, is_enabled: true, position: 1}, ...]

  ## JSON Storage Format

  Languages are stored in the `multi_language_config` setting as JSON:

      {
        "languages": [
          {
            "code": "en",
            "name": "English",
            "is_default": true,
            "is_enabled": true,
            "position": 1
          },
          {
            "code": "es",
            "name": "Spanish",
            "is_default": false,
            "is_enabled": true,
            "position": 2
          }
        ]
      }
  """

  alias PhoenixKit.Settings

  @config_key "multi_language_config"
  @enabled_key "multi_language_enabled"
  @module_name "multi_language"

  # Default configuration when system is first enabled
  @default_config %{
    "languages" => [
      %{
        "code" => "en",
        "name" => "English",
        "is_default" => true,
        "is_enabled" => true,
        "position" => 1
      }
    ]
  }

  ## --- System Management Functions ---

  @doc """
  Checks if the multi-language system is enabled.

  Returns true if the system is enabled, false otherwise.

  ## Examples

      iex> PhoenixKit.MultiLanguage.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enables the multi-language system and creates default configuration.

  Creates the initial system configuration with English as the default language.
  Updates both the enabled flag and the JSON configuration.

  Returns `{:ok, config}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> PhoenixKit.MultiLanguage.enable_system()
      {:ok, %{"languages" => [%{"code" => "en", ...}]}}
  """
  def enable_system do
    # Enable the system
    case Settings.update_boolean_setting_with_module(@enabled_key, true, @module_name) do
      {:ok, _setting} ->
        # Create initial JSON configuration with default English
        case Settings.update_json_setting_with_module(@config_key, @default_config, @module_name) do
          {:ok, _setting} -> {:ok, @default_config}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Disables the multi-language system.

  Turns off the multi-language system but preserves the language configuration.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.MultiLanguage.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  @doc """
  Gets the complete multi-language system configuration.

  Returns a map with system status and language configuration.

  ## Examples

      iex> PhoenixKit.MultiLanguage.get_config()
      %{
        enabled: true,
        languages: [%{"code" => "en", "name" => "English", ...}],
        language_count: 1,
        enabled_count: 1,
        default_language: %{"code" => "en", "name" => "English", ...}
      }
  """
  def get_config do
    enabled = enabled?()
    languages = get_languages()
    enabled_languages = Enum.filter(languages, & &1["is_enabled"])
    default_language = Enum.find(languages, & &1["is_default"])

    %{
      enabled: enabled,
      languages: languages,
      language_count: length(languages),
      enabled_count: length(enabled_languages),
      default_language: default_language
    }
  end

  ## --- Language Management Functions ---

  @doc """
  Gets all configured languages from the JSON setting.

  Returns a list of language maps, or empty list if not configured.

  ## Examples

      iex> PhoenixKit.MultiLanguage.get_languages()
      [%{"code" => "en", "name" => "English", "is_default" => true, ...}]
  """
  def get_languages do
    case Settings.get_json_setting(@config_key) do
      %{"languages" => languages} when is_list(languages) -> languages
      _ -> []
    end
  end

  @doc """
  Gets only enabled languages, sorted by position.

  Returns a list of enabled language maps.

  ## Examples

      iex> PhoenixKit.MultiLanguage.get_enabled_languages()
      [%{"code" => "en", "name" => "English", ...}]
  """
  def get_enabled_languages do
    get_languages()
    |> Enum.filter(& &1["is_enabled"])
    |> Enum.sort_by(& &1["position"])
  end

  @doc """
  Gets the default language.

  Returns the language map marked as default, or nil if none found.

  ## Examples

      iex> PhoenixKit.MultiLanguage.get_default_language()
      %{"code" => "en", "name" => "English", "is_default" => true, ...}
  """
  def get_default_language do
    get_languages()
    |> Enum.find(& &1["is_default"])
  end

  @doc """
  Adds a new language to the system.

  Takes a map with language attributes and adds it to the configuration.
  Automatically assigns the next position number.

  ## Required attributes
  - `code`: Language code (unique)
  - `name`: Full language name

  ## Optional attributes
  - `is_enabled`: Defaults to true
  - `is_default`: Defaults to false (only one default allowed)

  ## Examples

      iex> PhoenixKit.MultiLanguage.add_language(%{code: "es", name: "Spanish"})
      {:ok, updated_config}

      iex> PhoenixKit.MultiLanguage.add_language(%{code: "en", name: "English"})
      {:error, "Language code already exists"}
  """
  def add_language(attrs) when is_map(attrs) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    # Check if language code already exists
    code = Map.get(attrs, "code") || Map.get(attrs, :code)

    if Enum.any?(current_languages, &(&1["code"] == code)) do
      {:error, "Language code already exists"}
    else
      # Create new language with defaults
      new_language = %{
        "code" => code,
        "name" => Map.get(attrs, "name") || Map.get(attrs, :name),
        "is_default" => Map.get(attrs, "is_default") || Map.get(attrs, :is_default) || false,
        "is_enabled" => Map.get(attrs, "is_enabled") || Map.get(attrs, :is_enabled) || true,
        "position" => get_next_position(current_languages)
      }

      # If setting as default, remove default from other languages
      updated_languages =
        if new_language["is_default"] do
          Enum.map(current_languages, &Map.put(&1, "is_default", false))
        else
          current_languages
        end

      # Add new language
      final_languages = updated_languages ++ [new_language]
      updated_config = Map.put(current_config, "languages", final_languages)

      # Save updated configuration
      case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
        {:ok, _setting} -> {:ok, updated_config}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Updates an existing language in the system.

  Takes a language code and map of attributes to update.

  ## Examples

      iex> PhoenixKit.MultiLanguage.update_language("es", %{name: "Español"})
      {:ok, updated_config}

      iex> PhoenixKit.MultiLanguage.update_language("nonexistent", %{name: "Test"})
      {:error, "Language not found"}
  """
  def update_language(code, attrs) when is_binary(code) and is_map(attrs) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    case Enum.find_index(current_languages, &(&1["code"] == code)) do
      nil ->
        {:error, "Language not found"}

      index ->
        # Update the language
        current_language = Enum.at(current_languages, index)
        updated_language = Map.merge(current_language, stringify_keys(attrs))

        # If setting as default, remove default from other languages
        updated_languages =
          if updated_language["is_default"] do
            current_languages
            |> List.replace_at(index, updated_language)
            |> Enum.with_index()
            |> Enum.map(fn {lang, idx} ->
              if idx != index, do: Map.put(lang, "is_default", false), else: lang
            end)
          else
            List.replace_at(current_languages, index, updated_language)
          end

        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Removes a language from the system.

  Cannot remove the default language or the last remaining language.

  ## Examples

      iex> PhoenixKit.MultiLanguage.remove_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.MultiLanguage.remove_language("en")  # if it's default
      {:error, "Cannot remove default language"}
  """
  def remove_language(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    language_to_remove = Enum.find(current_languages, &(&1["code"] == code))

    cond do
      is_nil(language_to_remove) ->
        {:error, "Language not found"}

      language_to_remove["is_default"] ->
        {:error, "Cannot remove default language"}

      length(current_languages) <= 1 ->
        {:error, "Cannot remove the last language"}

      true ->
        updated_languages = Enum.reject(current_languages, &(&1["code"] == code))
        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Sets a new default language.

  Removes default status from all other languages and sets the specified language as default.

  ## Examples

      iex> PhoenixKit.MultiLanguage.set_default_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.MultiLanguage.set_default_language("nonexistent")
      {:error, "Language not found"}
  """
  def set_default_language(code) when is_binary(code) do
    update_language(code, %{"is_default" => true})
  end

  @doc """
  Enables a specific language.

  ## Examples

      iex> PhoenixKit.MultiLanguage.enable_language("es")
      {:ok, updated_config}
  """
  def enable_language(code) when is_binary(code) do
    update_language(code, %{"is_enabled" => true})
  end

  @doc """
  Disables a specific language.

  Cannot disable the default language.

  ## Examples

      iex> PhoenixKit.MultiLanguage.disable_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.MultiLanguage.disable_language("en")  # if it's default
      {:error, "Cannot disable default language"}
  """
  def disable_language(code) when is_binary(code) do
    current_languages = get_languages()
    language = Enum.find(current_languages, &(&1["code"] == code))

    if language && language["is_default"] do
      {:error, "Cannot disable default language"}
    else
      update_language(code, %{"is_enabled" => false})
    end
  end

  ## --- Private Helper Functions ---

  # Get the next position number for a new language
  defp get_next_position(languages) when is_list(languages) do
    case Enum.map(languages, & &1["position"]) |> Enum.max() do
      nil -> 1
      max_position -> max_position + 1
    end
  end

  # Convert atom keys to string keys for JSON storage
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
