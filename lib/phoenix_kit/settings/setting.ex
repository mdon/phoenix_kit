defmodule PhoenixKit.Settings.Setting do
  @moduledoc """
  Setting schema for PhoenixKit system settings.

  This schema defines system-wide settings that can be configured through
  the admin panel. Settings are stored as key-value pairs with timestamps.

  ## Fields

  - `key`: Setting identifier (unique, required)
  - `value`: Setting value (string format)
  - `module`: Module/feature identifier for organization (optional)
  - `date_added`: When the setting was first created
  - `date_updated`: When the setting was last modified

  ## Default Settings

  PhoenixKit includes three default system settings:

  - **time_zone**: System timezone offset (default: "0" for UTC)
  - **date_format**: Date display format (default: "Y-m-d")
  - **time_format**: Time display format (default: "H:i" for 24-hour)

  ## Usage Examples

      # Create a new setting
      %Setting{}
      |> Setting.changeset(%{key: "theme", value: "dark"})
      |> Repo.insert()

      # Update existing setting
      setting
      |> Setting.changeset(%{value: "light"})
      |> Repo.update()
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_settings" do
    field :key, :string
    field :value, :string
    field :module, :string
    field :date_added, :utc_datetime_usec
    field :date_updated, :utc_datetime_usec
  end

  @doc """
  Creates a changeset for setting creation and updates.

  Validates that key and value are present and key is unique.
  Automatically sets date_updated to current time on updates.
  """
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :module, :date_added, :date_updated])
    |> validate_required([:key, :value])
    |> validate_length(:key, min: 1, max: 255)
    |> validate_length(:value, min: 1, max: 1000)
    |> validate_length(:module, max: 255)
    |> unique_constraint(:key, name: :phoenix_kit_settings_key_uidx)
    |> maybe_set_timestamps()
  end

  @doc """
  Creates a changeset for updating only the value field.

  This is used when updating existing settings through the admin panel.
  Automatically updates the date_updated timestamp.
  """
  def update_changeset(setting, attrs) do
    setting
    |> cast(attrs, [:value, :module])
    |> validate_required([:value])
    |> validate_length(:value, min: 1, max: 1000)
    |> validate_length(:module, max: 255)
    |> put_change(:date_updated, DateTime.utc_now())
  end

  # Private helper to set timestamps on new records
  defp maybe_set_timestamps(changeset) do
    case get_field(changeset, :id) do
      nil ->
        now = DateTime.utc_now()

        changeset
        |> put_change(:date_added, now)
        |> put_change(:date_updated, now)

      _id ->
        put_change(changeset, :date_updated, DateTime.utc_now())
    end
  end
end
