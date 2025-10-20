defmodule PhoenixKit.UnderConstruction do
  @moduledoc """
  Under Construction (Maintenance Mode) module for PhoenixKit.

  This module provides a system-wide maintenance mode that shows an
  "Under Construction" page to all non-admin users while allowing
  admins and owners to access the site normally.

  ## Settings

  The module uses the following settings stored in the database:
  - `under_construction_module_enabled` - Boolean to enable/disable the module settings page (default: false)
  - `under_construction_enabled` - Boolean to enable/disable maintenance mode (default: false)
  - `under_construction_header` - Main heading text (default: "Under Construction")
  - `under_construction_subtext` - Descriptive subtext (default: "We'll be back soon")

  ## Usage

      # Check if module is enabled (settings page accessible)
      if PhoenixKit.UnderConstruction.module_enabled?() do
        # Show settings page
      end

      # Check if maintenance mode is enabled
      if PhoenixKit.UnderConstruction.enabled?() do
        # Show under construction page to non-admin users
      end

      # Enable module (makes settings page accessible)
      PhoenixKit.UnderConstruction.enable_module()

      # Enable maintenance mode (shows maintenance page to users)
      PhoenixKit.UnderConstruction.enable_system()

      # Get module configuration
      config = PhoenixKit.UnderConstruction.get_config()
      # => %{module_enabled: true, enabled: true, header: "...", subtext: "..."}
  """

  alias PhoenixKit.Settings

  @default_header "Under Construction"
  @default_subtext "We'll be back soon. Our team is working hard to bring you something amazing!"

  @doc """
  Checks if the Under Construction module is enabled (settings page accessible).

  ## Examples

      iex> PhoenixKit.UnderConstruction.module_enabled?()
      false
  """
  def module_enabled? do
    Settings.get_boolean_setting("under_construction_module_enabled", false)
  end

  @doc """
  Enables the Under Construction module (makes settings page accessible).
  """
  def enable_module do
    Settings.update_boolean_setting("under_construction_module_enabled", true)
  end

  @doc """
  Disables the Under Construction module (hides settings page).
  """
  def disable_module do
    Settings.update_boolean_setting("under_construction_module_enabled", false)
  end

  @doc """
  Checks if Under Construction (maintenance mode) is enabled.

  ## Examples

      iex> PhoenixKit.UnderConstruction.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("under_construction_enabled", false)
  end

  @doc """
  Enables the Under Construction (maintenance mode).

  When enabled, all non-admin users will see the maintenance page.
  """
  def enable_system do
    Settings.update_boolean_setting("under_construction_enabled", true)
  end

  @doc """
  Disables the Under Construction (maintenance mode).

  When disabled, all users can access the site normally.
  """
  def disable_system do
    Settings.update_boolean_setting("under_construction_enabled", false)
  end

  @doc """
  Gets the header text for the under construction page.

  ## Examples

      iex> PhoenixKit.UnderConstruction.get_header()
      "Under Construction"
  """
  def get_header do
    Settings.get_setting("under_construction_header", @default_header)
  end

  @doc """
  Updates the header text for the under construction page.
  """
  def update_header(header) when is_binary(header) do
    Settings.update_setting("under_construction_header", header)
  end

  @doc """
  Gets the subtext for the under construction page.

  ## Examples

      iex> PhoenixKit.UnderConstruction.get_subtext()
      "We'll be back soon..."
  """
  def get_subtext do
    Settings.get_setting("under_construction_subtext", @default_subtext)
  end

  @doc """
  Updates the subtext for the under construction page.
  """
  def update_subtext(subtext) when is_binary(subtext) do
    Settings.update_setting("under_construction_subtext", subtext)
  end

  @doc """
  Gets the configuration for the Under Construction module.

  Returns a map with:
  - `module_enabled` - Boolean indicating if module settings page is accessible
  - `enabled` - Boolean indicating if maintenance mode is enabled
  - `header` - Main heading text
  - `subtext` - Descriptive subtext

  ## Examples

      iex> PhoenixKit.UnderConstruction.get_config()
      %{
        module_enabled: false,
        enabled: false,
        header: "Under Construction",
        subtext: "We'll be back soon..."
      }
  """
  def get_config do
    %{
      module_enabled: module_enabled?(),
      enabled: enabled?(),
      header: get_header(),
      subtext: get_subtext()
    }
  end
end
