defmodule PhoenixKit.Utils.Date do
  @moduledoc """
  Date and time formatting utilities for PhoenixKit.

  This module provides robust date and time formatting functionality using Timex,
  supporting various format codes used throughout the PhoenixKit system.

  ## Core Functions

  ### Date Formatting
  - `format_date/2` - Format a date using PHP-style format codes
  - `format_time/2` - Format a time using PHP-style format codes  
  - `get_date_examples/1` - Generate example formatted dates
  - `get_time_examples/1` - Generate example formatted times

  ### Format Support

  The module supports the following format codes:

  **Date Formats:**
  - `Y-m-d` - 2025-09-02 (ISO format)
  - `m/d/Y` - 09/02/2025 (US format)
  - `d/m/Y` - 02/09/2025 (European format)  
  - `d.m.Y` - 02.09.2025 (German format)
  - `d-m-Y` - 02-09-2025 (Alternative European)
  - `F j, Y` - September 2, 2025 (Long format)

  **Time Formats:**
  - `H:i` - 15:30 (24-hour format)
  - `h:i A` - 3:30 PM (12-hour format with AM/PM)

  ## Usage Examples

      # Format a date
      date = Date.utc_today()
      PhoenixKit.Utils.Date.format_date(date, "F j, Y")
      # => "September 2, 2025"

      # Format a time
      time = Time.utc_now()
      PhoenixKit.Utils.Date.format_time(time, "h:i A")  
      # => "3:30 PM"

      # Get examples for all date formats
      PhoenixKit.Utils.Date.get_date_examples(Date.utc_today())
      # => %{"Y-m-d" => "2025-09-02", "F j, Y" => "September 2, 2025", ...}

  ## Implementation

  This module uses Timex for robust internationalized date/time formatting
  with extensive format support and proper locale handling.
  """

  use Timex
  alias PhoenixKit.Settings

  @doc """
  Formats a date according to the specified format string.

  Uses Timex for robust date formatting with extensive format support.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "Y-m-d")
      "2024-01-15"
      
      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "m/d/Y")
      "01/15/2024"
      
      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "F j, Y")
      "January 15, 2024"
  """
  def format_date(date, format) do
    timex_format = get_timex_format(format)
    format_with_timex(date, timex_format)
  end

  # Private helper functions to reduce complexity
  defp get_timex_format(format) do
    case format do
      "Y-m-d" -> "{YYYY}-{0M}-{0D}"
      "m/d/Y" -> "{0M}/{0D}/{YYYY}"
      "d/m/Y" -> "{0D}/{0M}/{YYYY}"
      "d.m.Y" -> "{0D}.{0M}.{YYYY}"
      "d-m-Y" -> "{0D}-{0M}-{YYYY}"
      "F j, Y" -> "{Mfull} {D}, {YYYY}"
      # Default to Y-m-d format
      _ -> "{YYYY}-{0M}-{0D}"
    end
  end

  defp format_with_timex(date, timex_format) do
    case Timex.format(date, timex_format) do
      {:ok, formatted} -> formatted
      # Fallback to ISO format
      {:error, _} -> Date.to_string(date)
    end
  end

  @doc """
  Formats a time according to the specified format string.

  Uses Timex for robust time formatting with extensive format support.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_time(~T[15:30:00], "H:i")
      "15:30"
      
      iex> PhoenixKit.Utils.Date.format_time(~T[15:30:00], "h:i A")
      "3:30 PM"
  """
  def format_time(time, format) do
    # Map our format codes to Timex format strings
    timex_format =
      case format do
        "H:i" -> "{h24}:{m}"
        "h:i A" -> "{h12}:{m} {AM}"
        # Default to 24-hour format
        _ -> "{h24}:{m}"
      end

    case Timex.format(time, timex_format) do
      {:ok, formatted} -> formatted
      # Fallback to ISO format
      {:error, _} -> Time.to_string(time)
    end
  end

  @doc """
  Generates example formatted dates for all supported formats.

  Returns a map with format codes as keys and formatted examples as values.
  Useful for generating dropdown options and previews.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_date_examples(~D[2024-01-15])
      %{
        "Y-m-d" => "2024-01-15",
        "m/d/Y" => "01/15/2024", 
        "d/m/Y" => "15/01/2024",
        "d.m.Y" => "15.01.2024",
        "d-m-Y" => "15-01-2024",
        "F j, Y" => "January 15, 2024"
      }
  """
  def get_date_examples(date) do
    %{
      "Y-m-d" => format_date(date, "Y-m-d"),
      "m/d/Y" => format_date(date, "m/d/Y"),
      "d/m/Y" => format_date(date, "d/m/Y"),
      "d.m.Y" => format_date(date, "d.m.Y"),
      "d-m-Y" => format_date(date, "d-m-Y"),
      "F j, Y" => format_date(date, "F j, Y")
    }
  end

  @doc """
  Generates example formatted times for all supported formats.

  Returns a map with format codes as keys and formatted examples as values.
  Useful for generating dropdown options and previews.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_time_examples(~T[15:30:00])
      %{
        "H:i" => "15:30",
        "h:i A" => "3:30 PM"
      }
  """
  def get_time_examples(time) do
    %{
      "H:i" => format_time(time, "H:i"),
      "h:i A" => format_time(time, "h:i A")
    }
  end

  @doc """
  Formats a datetime (NaiveDateTime) according to the specified date format.

  Extracts the date part and formats it using format_date/2.
  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime(~N[2024-01-15 15:30:00], "F j, Y")
      "January 15, 2024"
      
      iex> PhoenixKit.Utils.Date.format_datetime(nil, "Y-m-d")
      "Never"
  """
  def format_datetime(nil, _format), do: "Never"

  def format_datetime(datetime, format) do
    date = NaiveDateTime.to_date(datetime)
    format_date(date, format)
  end

  @doc """
  Gets all supported date format options with dynamic examples.

  Returns a list of {label, format_code} tuples suitable for dropdown menus.
  Each label includes the format description and a current date example.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_date_format_options()
      [
        {"YYYY-MM-DD (2025-09-02)", "Y-m-d"},
        {"MM/DD/YYYY (09/02/2025)", "m/d/Y"},
        # ... more formats
      ]
  """
  def get_date_format_options do
    today = Date.utc_today()
    date_examples = get_date_examples(today)

    [
      {"YYYY-MM-DD (#{date_examples["Y-m-d"]})", "Y-m-d"},
      {"MM/DD/YYYY (#{date_examples["m/d/Y"]})", "m/d/Y"},
      {"DD/MM/YYYY (#{date_examples["d/m/Y"]})", "d/m/Y"},
      {"DD.MM.YYYY (#{date_examples["d.m.Y"]})", "d.m.Y"},
      {"DD-MM-YYYY (#{date_examples["d-m-Y"]})", "d-m-Y"},
      {"Month Day, Year (#{date_examples["F j, Y"]})", "F j, Y"}
    ]
  end

  @doc """
  Gets all supported time format options with dynamic examples.

  Returns a list of {label, format_code} tuples suitable for dropdown menus.
  Each label includes the format description and a current time example.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_time_format_options()
      [
        {"24 Hour (15:30)", "H:i"},
        {"12 Hour (3:30 PM)", "h:i A"}
      ]
  """
  def get_time_format_options do
    now = Time.utc_now()
    time_examples = get_time_examples(now)

    [
      {"24 Hour (#{time_examples["H:i"]})", "H:i"},
      {"12 Hour (#{time_examples["h:i A"]})", "h:i A"}
    ]
  end

  ## Settings-Aware Functions
  ## These functions automatically load format preferences from Settings

  @doc """
  Formats a datetime using the user's date format preference from Settings.
  
  Automatically loads the date_format setting and applies it to the datetime.
  Returns "Never" for nil values.
  
  ## Examples
  
      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(~N[2024-01-15 15:30:00])
      "January 15, 2024"  # If user has "F j, Y" format selected
      
      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(nil)
      "Never"
  """
  def format_datetime_with_user_format(datetime) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_datetime(datetime, date_format)
  end

  @doc """
  Formats a date using the user's date format preference from Settings.
  
  Automatically loads the date_format setting and applies it to the date.
  
  ## Examples
  
      iex> PhoenixKit.Utils.Date.format_date_with_user_format(~D[2024-01-15])
      "January 15, 2024"  # If user has "F j, Y" format selected
  """
  def format_date_with_user_format(date) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_date(date, date_format)
  end

  @doc """
  Formats a time using the user's time format preference from Settings.
  
  Automatically loads the time_format setting and applies it to the time.
  
  ## Examples
  
      iex> PhoenixKit.Utils.Date.format_time_with_user_format(~T[15:30:00])
      "3:30 PM"  # If user has "h:i A" format selected
  """
  def format_time_with_user_format(time) do
    time_format = Settings.get_setting("time_format", "H:i")
    format_time(time, time_format)
  end
end
