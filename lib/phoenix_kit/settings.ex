defmodule PhoenixKit.Settings do
  @moduledoc """
  The Settings context for system configuration management.

  This module provides functions for managing system-wide settings in PhoenixKit.
  Settings are stored in the database and can be updated through the admin panel.

  ## Core Functions

  ### Settings Management

  - `get_setting/1` - Get a setting value by key
  - `get_setting/2` - Get a setting value with default fallback
  - `update_setting/2` - Update or create a setting
  - `list_all_settings/0` - Get all settings as a map

  ### Default Settings

  The system includes three core settings:
  - `time_zone`: System timezone offset
  - `date_format`: Date display format
  - `time_format`: Time display format

  ## Usage Examples

      # Get a setting with default
      timezone = PhoenixKit.Settings.get_setting("time_zone", "0")

      # Update a setting
      {:ok, setting} = PhoenixKit.Settings.update_setting("time_zone", "+1")

      # Get all settings as a map
      settings = PhoenixKit.Settings.list_all_settings()
      # => %{"time_zone" => "0", "date_format" => "Y-m-d", "time_format" => "H:i"}

  ## Configuration

  The context uses PhoenixKit's configured repository and respects table prefixes
  set during installation.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Gets the configured repository for database operations.
  # Uses PhoenixKit.RepoHelper to get the configured repo with proper prefix support.
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  @doc """
  Gets a setting value by key.

  Returns the setting value as a string, or nil if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_setting("time_zone")
      "0"

      iex> PhoenixKit.Settings.get_setting("non_existent")
      nil
  """
  def get_setting(key) when is_binary(key) do
    case repo().get_by(Setting, key: key) do
      %Setting{value: value} -> value
      nil -> nil
    end
  end

  @doc """
  Gets a setting value by key with a default fallback.

  Returns the setting value as a string, or the default if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_setting("time_zone", "0")
      "0"

      iex> PhoenixKit.Settings.get_setting("non_existent", "default")
      "default"
  """
  def get_setting(key, default) when is_binary(key) do
    get_setting(key) || default
  end

  @doc """
  Updates or creates a setting with the given key and value.

  If the setting exists, updates its value and timestamp.
  If the setting doesn't exist, creates a new one.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.Settings.update_setting("time_zone", "+1")
      {:ok, %Setting{key: "time_zone", value: "+1"}}

      iex> PhoenixKit.Settings.update_setting("", "invalid")
      {:error, %Ecto.Changeset{}}
  """
  def update_setting(key, value) when is_binary(key) and is_binary(value) do
    case repo().get_by(Setting, key: key) do
      %Setting{} = setting ->
        setting
        |> Setting.update_changeset(%{value: value})
        |> repo().update()

      nil ->
        %Setting{}
        |> Setting.changeset(%{key: key, value: value})
        |> repo().insert()
    end
  end

  @doc """
  Lists all settings as a map with keys as setting names and values as setting values.

  Returns a map where keys are setting names and values are setting values.
  Useful for loading all settings at once for forms or configuration.

  ## Examples

      iex> PhoenixKit.Settings.list_all_settings()
      %{
        "time_zone" => "0",
        "date_format" => "Y-m-d",
        "time_format" => "H:i"
      }
  """
  def list_all_settings do
    Setting
    |> select([s], {s.key, s.value})
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Gets all settings with their full details (including timestamps).

  Returns a list of Setting structs. Useful for admin interfaces
  that need to show when settings were created/updated.

  ## Examples

      iex> PhoenixKit.Settings.list_settings()
      [
        %Setting{key: "time_zone", value: "0", date_added: ~U[2024-01-01 00:00:00.000000Z]},
        %Setting{key: "date_format", value: "Y-m-d", date_added: ~U[2024-01-01 00:00:00.000000Z]}
      ]
  """
  def list_settings do
    Setting
    |> order_by([s], s.key)
    |> repo().all()
  end

  @doc """
  Gets the available options for each setting type.

  Returns a map with setting keys and their available options as {label, value} tuples.
  Used to populate dropdown menus in the admin interface.

  ## Examples

      iex> PhoenixKit.Settings.get_setting_options()
      %{
        "time_zone" => [{"UTC-12", "-12"}, {"UTC+0 (GMT)", "0"}, {"UTC+8", "8"}],
        "date_format" => [{"YYYY-MM-DD", "Y-m-d"}, {"MM/DD/YYYY", "m/d/Y"}],
        "time_format" => [{"24 Hour (15:30)", "H:i"}, {"12 Hour (3:30 PM)", "h:i A"}]
      }
  """
  def get_setting_options do
    %{
      "time_zone" => [
        {"UTC-12 (Baker Island)", "-12"},
        {"UTC-11 (American Samoa)", "-11"},
        {"UTC-10 (Hawaii)", "-10"},
        {"UTC-9 (Alaska)", "-9"},
        {"UTC-8 (Pacific Time)", "-8"},
        {"UTC-7 (Mountain Time)", "-7"},
        {"UTC-6 (Central Time)", "-6"},
        {"UTC-5 (Eastern Time)", "-5"},
        {"UTC-4 (Atlantic Time)", "-4"},
        {"UTC-3 (Argentina)", "-3"},
        {"UTC-2 (Mid-Atlantic)", "-2"},
        {"UTC-1 (Cape Verde)", "-1"},
        {"UTC+0 (GMT/London)", "0"},
        {"UTC+1 (Central Europe)", "1"},
        {"UTC+2 (Eastern Europe)", "2"},
        {"UTC+3 (Moscow)", "3"},
        {"UTC+4 (Dubai)", "4"},
        {"UTC+5 (Pakistan)", "5"},
        {"UTC+6 (Bangladesh)", "6"},
        {"UTC+7 (Thailand)", "7"},
        {"UTC+8 (China/Singapore)", "8"},
        {"UTC+9 (Japan/Korea)", "9"},
        {"UTC+10 (Australia East)", "10"},
        {"UTC+11 (Solomon Islands)", "11"},
        {"UTC+12 (New Zealand)", "12"}
      ],
      "date_format" => UtilsDate.get_date_format_options(),
      "time_format" => UtilsDate.get_time_format_options()
    }
  end

  @doc """
  Gets default values for all settings.

  Returns a map with setting keys and their default values.
  These defaults match the ones defined in the V03 migration.

  ## Examples

      iex> PhoenixKit.Settings.get_defaults()
      %{
        "time_zone" => "0",
        "date_format" => "Y-m-d",
        "time_format" => "H:i"
      }
  """
  def get_defaults do
    %{
      "project_title" => "PhoenixKit",
      "time_zone" => "0",
      "date_format" => "Y-m-d",
      "time_format" => "H:i"
    }
  end

  @doc """
  Gets the display label for a timezone value.

  ## Examples

      iex> PhoenixKit.Settings.get_timezone_label("0", get_setting_options())
      "UTC+0 (GMT/London)"
  """
  def get_timezone_label(value, setting_options) do
    case Enum.find(setting_options["time_zone"], fn {_label, val} -> val == value end) do
      {label, _value} -> label
      nil -> "UTC#{if value != "0", do: value, else: ""}"
    end
  end

  @doc """
  Gets the display label for a setting option value.

  ## Examples

      iex> options = [{"YYYY-MM-DD", "Y-m-d"}, {"MM/DD/YYYY", "m/d/Y"}]
      iex> PhoenixKit.Settings.get_option_label("Y-m-d", options)
      "YYYY-MM-DD"
  """
  def get_option_label(value, options) do
    case Enum.find(options, fn {_label, val} -> val == value end) do
      {label, _value} -> label
      nil -> value
    end
  end
end
