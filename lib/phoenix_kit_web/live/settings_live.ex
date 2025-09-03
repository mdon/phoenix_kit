defmodule PhoenixKitWeb.Live.SettingsLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Date, as: PKDate
  alias PhoenixKit.Settings

  # Embedded schema for form validation
  defmodule SettingsForm do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :time_zone, :string
      field :date_format, :string
      field :time_format, :string
    end

    def changeset(form, attrs) do
      form
      |> cast(attrs, [:time_zone, :date_format, :time_format])
      |> validate_required([:time_zone, :date_format, :time_format])
    end
  end

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Load current settings from database
    current_settings = Settings.list_all_settings()
    defaults = Settings.get_defaults()
    setting_options = Settings.get_setting_options()

    # Merge defaults with current settings to ensure all keys exist
    merged_settings = Map.merge(defaults, current_settings)

    # Create form changeset
    changeset = create_settings_changeset(merged_settings)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Settings")
      |> assign(:settings, merged_settings)
      # Track saved values separately
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)

    {:ok, socket}
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    # Update the changeset with new values for validation
    changeset = create_settings_changeset(settings_params) |> Map.put(:action, :validate)

    # Update the current settings to reflect the pending changes (but don't save to DB)
    socket =
      socket
      |> assign(:settings, settings_params)
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings_params}, socket) do
    socket = assign(socket, :saving, true)

    case update_all_settings(settings_params) do
      {:ok, updated_settings} ->
        # Update socket with new settings
        changeset = create_settings_changeset(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          # Update saved values
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> put_flash(:info, "Settings updated successfully")

        {:noreply, socket}

      {:error, errors} ->
        error_msg = format_error_message(errors)

        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, error_msg)

        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For SettingsLive, always return settings path
    "/phoenix_kit/admin/settings"
  end

  # Create a changeset for form validation
  defp create_settings_changeset(settings) do
    # Convert string keys to atoms for the embedded schema
    attrs = atomize_keys(settings)

    # Create the form struct with current values
    form_data = struct(SettingsForm, attrs)

    # Create changeset
    SettingsForm.changeset(form_data, attrs)
  end

  # Helper to convert string keys to atoms for changeset
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # Update all settings in the database
  defp update_all_settings(settings_params) do
    updated_settings =
      Enum.reduce(settings_params, %{}, fn {key, value}, acc ->
        case Settings.update_setting(key, value) do
          {:ok, _setting} -> Map.put(acc, key, value)
          {:error, _changeset} -> acc
        end
      end)

    if map_size(updated_settings) == map_size(settings_params) do
      {:ok, updated_settings}
    else
      {:error, ["Some settings failed to update"]}
    end
  end

  # Format error messages for display
  defp format_error_message(errors) when is_list(errors) do
    errors
    |> List.first()
    |> to_string()
  end

  # Helper functions for template to show dropdown labels
  def get_timezone_label(value, setting_options) do
    Settings.get_timezone_label(value, setting_options)
  end

  def get_option_label(value, options) do
    Settings.get_option_label(value, options)
  end

  # Helper functions for template to show current format examples
  def get_current_date_example(format) do
    PKDate.format_date(Date.utc_today(), format)
  end

  def get_current_time_example(format) do
    PKDate.format_time(Time.utc_now(), format)
  end
end
