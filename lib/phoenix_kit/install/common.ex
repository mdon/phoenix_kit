defmodule PhoenixKit.Install.Common do
  @moduledoc """
  Common utilities shared between PhoenixKit installation and update tasks.

  This module provides shared functionality for:
  - Timestamp generation
  - Version formatting
  - Status checking
  - Migration detection
  """

  alias PhoenixKit.Migrations.Postgres

  @doc """
  Generates timestamp in Ecto migration format.

  ## Examples

      iex> PhoenixKit.Install.Common.generate_timestamp()
      "20250908123045"
  """
  def generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  @doc """
  Pads a number with leading zero if less than 10.

  ## Examples

      iex> PhoenixKit.Install.Common.pad(5)
      "05"

      iex> PhoenixKit.Install.Common.pad(12)
      "12"
  """
  def pad(i) when i < 10, do: <<?0, ?0 + i>>
  def pad(i), do: to_string(i)

  @doc """
  Pads version number for consistent naming.

  ## Examples

      iex> PhoenixKit.Install.Common.pad_version(1)
      "01"

      iex> PhoenixKit.Install.Common.pad_version(15)
      "15"
  """
  def pad_version(version) when version < 10, do: "0#{version}"
  def pad_version(version), do: to_string(version)

  @doc """
  Checks the current installation status for a given prefix.

  Returns one of:
  - `{:not_installed}` - PhoenixKit is not installed
  - `{:current_version, version}` - PhoenixKit is installed with given version

  ## Parameters
  - `prefix` - Database schema prefix (default: "public")

  ## Examples

      iex> PhoenixKit.Install.Common.check_installation_status("public")
      {:current_version, 3}

      iex> PhoenixKit.Install.Common.check_installation_status("auth")
      {:not_installed}
  """
  def check_installation_status(prefix \\ "public") do
    # Use the same version detection logic as the migration system
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}

    try do
      # Use PhoenixKit's centralized runtime version detection function
      current_version = Postgres.migrated_version_runtime(opts)

      if current_version == 0 do
        # Check if migration files exist but haven't been run
        case find_existing_phoenix_kit_migrations() do
          [] -> {:not_installed}
          # Migration files exist but not run - treat as V01 (first version)
          _migrations -> {:current_version, 1}
        end
      else
        {:current_version, current_version}
      end
    rescue
      _ ->
        # Database error, check migration files as fallback
        case find_existing_phoenix_kit_migrations() do
          [] -> {:not_installed}
          # Migration files exist but DB not accessible - assume V01
          _migrations -> {:current_version, 1}
        end
    end
  end

  @doc """
  Finds existing PhoenixKit migrations in the project.

  Returns a list of migration file paths.
  """
  def find_existing_phoenix_kit_migrations do
    if File.exists?("priv/repo/migrations") do
      "priv/repo/migrations"
      |> File.ls!()
      |> Enum.filter(&phoenix_kit_migration?/1)
      |> Enum.map(&Path.join("priv/repo/migrations", &1))
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Checks if a filename matches PhoenixKit migration pattern.

  ## Examples

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_add_phoenix_kit_tables.exs")
      true

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_create_users.exs")
      false
  """
  def phoenix_kit_migration?(filename) do
    (String.contains?(filename, "phoenix_kit") ||
       String.contains?(filename, "add_phoenix_kit") ||
       String.contains?(filename, "upgrade_phoenix_kit") ||
       String.contains?(filename, "update_phoenix_kit")) &&
      String.ends_with?(filename, ".exs")
  end

  @doc """
  Describes what changed between versions.

  ## Parameters
  - `from_version` - Starting version number
  - `to_version` - Target version number

  ## Returns
  String describing the changes between versions.
  """
  def describe_version_changes(from_version, to_version) do
    case {from_version, to_version} do
      {1, 3} ->
        "- Remove is_active column from role assignments (simplified role system)\n" <>
          "- Add settings table with user preferences support"

      {2, 3} ->
        "- Add settings table with user preferences support"

      {_, _} when from_version < to_version ->
        "- Various improvements and new features"

      {_, _} ->
        "- No changes (already up to date)"
    end
  end

  @doc """
  Gets current PhoenixKit version from migrations system.
  """
  def current_version, do: Postgres.current_version()

  @doc """
  Gets migrated version for given prefix.

  ## Parameters
  - `prefix` - Database schema prefix
  """
  def migrated_version(prefix \\ "public") do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    Postgres.migrated_version_runtime(opts)
  rescue
    _ -> 0
  end

  @doc """
  Checks if an update is needed from current to target version.

  ## Parameters
  - `prefix` - Database schema prefix
  - `force` - Force update even if already up to date

  ## Returns
  - `{:up_to_date, current_version}` - Already up to date
  - `{:update_needed, current_version, target_version}` - Update available
  - `{:not_installed}` - PhoenixKit not installed
  """
  def check_update_needed(prefix \\ "public", force \\ false) do
    case check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:current_version, current_version} ->
        target_version = current_version()

        cond do
          current_version >= target_version && !force ->
            {:up_to_date, current_version}

          current_version < target_version || force ->
            {:update_needed, current_version, target_version}

          true ->
            {:up_to_date, current_version}
        end
    end
  end
end
