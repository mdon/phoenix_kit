defmodule PhoenixKit.Languages do
  @moduledoc """
  Languages management for PhoenixKit - complete language configuration in a single module.

  This module provides management for language support in PhoenixKit applications.
  It handles language configuration, settings, and language data through JSON settings.

  ## Language Structure

  Each language has the following structure:
  - `code`: Language code (e.g., "en", "es", "fr")
  - `name`: Full language name (e.g., "English", "Spanish", "French")
  - `is_default`: Boolean indicating if this is the default language
  - `is_enabled`: Boolean indicating if this language is active

  ## Core Functions

  ### Languages Management
  - `enabled?/0` - Check if languages are enabled
  - `enable_system/0` - Enable languages with default English
  - `disable_system/0` - Disable languages
  - `get_config/0` - Get complete configuration

  ### Language Management
  - `get_languages/0` - Get all configured languages
  - `get_enabled_languages/0` - Get only enabled languages
  - `get_default_language/0` - Get the default language
  - `get_language/1` - Get a specific language by code
  - `get_language_codes/0` - Get list of all language codes
  - `get_enabled_language_codes/0` - Get list of enabled language codes
  - `valid_language?/1` - Check if a language code exists
  - `language_enabled?/1` - Check if a language is enabled
  - `add_language/1` - Add a new language to the system
  - `update_language/2` - Update an existing language
  - `remove_language/1` - Remove a language from the system
  - `set_default_language/1` - Set a new default language
  - `enable_language/1` - Enable a specific language
  - `disable_language/1` - Disable a specific language

  ## Usage Examples

      # Check if languages are enabled
      if PhoenixKit.Languages.enabled?() do
        # Languages are active
      end

      # Enable languages (creates default English language)
      {:ok, config} = PhoenixKit.Languages.enable_system()

      # Add a new language
      {:ok, config} = PhoenixKit.Languages.add_language(%{
        code: "es",
        name: "Spanish",
        is_enabled: true
      })

      # Get all languages
      languages = PhoenixKit.Languages.get_languages()
      # => [%{code: "en", name: "English", is_default: true, is_enabled: true, position: 1}, ...]

      # Get only enabled languages (most common use case)
      enabled_languages = PhoenixKit.Languages.get_enabled_languages()
      # => [%{code: "en", name: "English", ...}, %{code: "es", name: "Spanish", ...}]

      # Get a specific language by code
      spanish = PhoenixKit.Languages.get_language("es")
      # => %{code: "es", name: "Spanish", is_enabled: true, position: 2}

      # Get just the language codes
      codes = PhoenixKit.Languages.get_enabled_language_codes()
      # => ["en", "es", "fr"]

      # Check if a language is valid and enabled
      if PhoenixKit.Languages.language_enabled?("es") do
        # Use Spanish language
      end

  ## JSON Storage Format

  Languages are stored in the `languages_config` setting as JSON.
  The array order determines the display order:

      {
        "languages": [
          {
            "code": "en",
            "name": "English",
            "is_default": true,
            "is_enabled": true
          },
          {
            "code": "es",
            "name": "Spanish",
            "is_default": false,
            "is_enabled": true
          }
        ]
      }
  """

  alias PhoenixKit.Settings

  @config_key "languages_config"
  @enabled_key "languages_enabled"
  @module_name "languages"

  # Default configuration when system is first enabled
  @default_config %{
    "languages" => [
      %{
        "code" => "en",
        "name" => "English",
        "is_default" => true,
        "is_enabled" => true
      }
    ]
  }

  ## --- System Management Functions ---

  @doc """
  Checks if the language system is enabled.

  Returns true if the system is enabled, false otherwise.

  ## Examples

      iex> PhoenixKit.Languages.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enables the language system and creates default configuration.

  Creates the initial system configuration with English as the default language.
  Updates both the enabled flag and the JSON configuration.

  Returns `{:ok, config}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> PhoenixKit.Languages.enable_system()
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
  Disables the language system.

  Turns off the language system but preserves the language configuration.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.Languages.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  @doc """
  Gets the complete language system configuration.

  Returns a map with system status and language configuration.

  ## Examples

      iex> PhoenixKit.Languages.get_config()
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

      iex> PhoenixKit.Languages.get_languages()
      [%{"code" => "en", "name" => "English", "is_default" => true, ...}]

      # When system is disabled:
      iex> PhoenixKit.Languages.get_languages()
      []
  """
  def get_languages do
    if enabled?() do
      case Settings.get_json_setting(@config_key) do
        %{"languages" => languages} when is_list(languages) -> languages
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Gets only enabled languages, sorted by position.

  Returns a list of enabled language maps.

  ## Examples

      iex> PhoenixKit.Languages.get_enabled_languages()
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

      iex> PhoenixKit.Languages.get_default_language()
      %{"code" => "en", "name" => "English", "is_default" => true, ...}

      # When system is disabled:
      iex> PhoenixKit.Languages.get_default_language()
      nil
  """
  def get_default_language do
    if enabled?() do
      get_languages()
      |> Enum.find(& &1["is_default"])
    else
      nil
    end
  end

  @doc """
  Gets a specific language by its code.

  Returns the language map if found, or nil if not found.

  ## Examples

      iex> PhoenixKit.Languages.get_language("es")
      %{"code" => "es", "name" => "Spanish", "is_enabled" => true, "position" => 2}

      iex> PhoenixKit.Languages.get_language("invalid")
      nil
  """
  def get_language(code) when is_binary(code) do
    if enabled?() do
      get_languages()
      |> Enum.find(&(&1["code"] == code))
    else
      nil
    end
  end

  @doc """
  Gets a list of all language codes.

  Returns a list of language code strings.

  ## Examples

      iex> PhoenixKit.Languages.get_language_codes()
      ["en", "es", "fr"]
  """
  def get_language_codes do
    get_languages()
    |> Enum.map(& &1["code"])
  end

  @doc """
  Gets a list of enabled language codes, sorted by position.

  Returns a list of enabled language code strings.

  ## Examples

      iex> PhoenixKit.Languages.get_enabled_language_codes()
      ["en", "es"]
  """
  def get_enabled_language_codes do
    get_enabled_languages()
    |> Enum.map(& &1["code"])
  end

  @doc """
  Checks if a language code is valid (exists in configuration).

  Returns true if the language exists, false otherwise.

  ## Examples

      iex> PhoenixKit.Languages.valid_language?("es")
      true

      iex> PhoenixKit.Languages.valid_language?("invalid")
      false
  """
  def valid_language?(code) when is_binary(code) do
    not is_nil(get_language(code))
  end

  @doc """
  Checks if a language is enabled.

  Returns true if the language exists and is enabled, false otherwise.

  ## Examples

      iex> PhoenixKit.Languages.language_enabled?("es")
      true

      iex> PhoenixKit.Languages.language_enabled?("disabled_lang")
      false
  """
  def language_enabled?(code) when is_binary(code) do
    enabled?() &&
      case get_language(code) do
        %{"is_enabled" => true} -> true
        _ -> false
      end
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

      iex> PhoenixKit.Languages.add_language(%{code: "es", name: "Spanish"})
      {:ok, updated_config}

      iex> PhoenixKit.Languages.add_language(%{code: "en", name: "English"})
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
        "is_enabled" => Map.get(attrs, "is_enabled") || Map.get(attrs, :is_enabled) || true
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

      iex> PhoenixKit.Languages.update_language("es", %{name: "Español"})
      {:ok, updated_config}

      iex> PhoenixKit.Languages.update_language("nonexistent", %{name: "Test"})
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

      iex> PhoenixKit.Languages.remove_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.Languages.remove_language("en")  # if it's default
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

      iex> PhoenixKit.Languages.set_default_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.Languages.set_default_language("nonexistent")
      {:error, "Language not found"}
  """
  def set_default_language(code) when is_binary(code) do
    update_language(code, %{"is_default" => true})
  end

  @doc """
  Enables a specific language.

  ## Examples

      iex> PhoenixKit.Languages.enable_language("es")
      {:ok, updated_config}
  """
  def enable_language(code) when is_binary(code) do
    update_language(code, %{"is_enabled" => true})
  end

  @doc """
  Disables a specific language.

  Cannot disable the default language.

  ## Examples

      iex> PhoenixKit.Languages.disable_language("es")
      {:ok, updated_config}

      iex> PhoenixKit.Languages.disable_language("en")  # if it's default
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

  @doc """
  Moves a language up one position in the array.

  Moves the language one index earlier in the languages array. Cannot move the first language up.

  ## Examples

      iex> PhoenixKit.Languages.move_language_up("es")
      {:ok, updated_config}

      iex> PhoenixKit.Languages.move_language_up("en")  # if first in array
      {:error, "Language is already at the top"}
  """
  def move_language_up(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    # Find the index of the language to move
    current_index = Enum.find_index(current_languages, &(&1["code"] == code))

    if current_index do
      if current_index == 0 do
        {:error, "Language is already at the top"}
      else
        # Swap with the previous element in the array
        updated_languages =
          current_languages
          |> List.update_at(current_index, fn _ -> Enum.at(current_languages, current_index - 1) end)
          |> List.update_at(current_index - 1, fn _ -> Enum.at(current_languages, current_index) end)

        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, "Language not found"}
    end
  end

  @doc """
  Moves a language down one position in the array.

  Moves the language one index later in the languages array. Cannot move the last language down.

  ## Examples

      iex> PhoenixKit.Languages.move_language_down("en")
      {:ok, updated_config}

      iex> PhoenixKit.Languages.move_language_down("es")  # if last in array
      {:error, "Language is already at the bottom"}
  """
  def move_language_down(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    # Find the index of the language to move
    current_index = Enum.find_index(current_languages, &(&1["code"] == code))

    if current_index do
      max_index = length(current_languages) - 1

      if current_index == max_index do
        {:error, "Language is already at the bottom"}
      else
        # Swap with the next element in the array
        updated_languages =
          current_languages
          |> List.update_at(current_index, fn _ -> Enum.at(current_languages, current_index + 1) end)
          |> List.update_at(current_index + 1, fn _ -> Enum.at(current_languages, current_index) end)

        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, "Language not found"}
    end
  end

  ## --- Private Helper Functions ---

  # Convert atom keys to string keys for JSON storage
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
