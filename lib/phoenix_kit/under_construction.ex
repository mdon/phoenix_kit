defmodule PhoenixKit.UnderConstruction do
  @moduledoc """
  Under Construction (Maintenance Mode) module for PhoenixKit.

  This module provides a system-wide maintenance mode that shows an
  "Under Construction" page to all non-admin users while allowing
  admins and owners to access the site normally.

  ## Settings

  The module uses the following settings stored in the database:
  - `under_construction_enabled` - Boolean to enable/disable maintenance mode (default: false)
  - `under_construction_header` - Main heading text (default: "Under Construction")
  - `under_construction_subtext` - Descriptive subtext (default: "We'll be back soon")

  ## Usage

      # Check if maintenance mode is enabled
      if PhoenixKit.UnderConstruction.enabled?() do
        # Show under construction page to non-admin users
      end

      # Enable maintenance mode
      PhoenixKit.UnderConstruction.enable_system()

      # Disable maintenance mode
      PhoenixKit.UnderConstruction.disable_system()

      # Get module configuration
      config = PhoenixKit.UnderConstruction.get_config()
      # => %{enabled: true, header: "...", subtext: "..."}
  """

  alias PhoenixKit.Settings

  @default_header "Under Construction"
  @default_subtext "We'll be back soon. Our team is working hard to bring you something amazing!"

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
  - `enabled` - Boolean indicating if maintenance mode is enabled
  - `header` - Main heading text
  - `subtext` - Descriptive subtext

  ## Examples

      iex> PhoenixKit.UnderConstruction.get_config()
      %{
        enabled: false,
        header: "Under Construction",
        subtext: "We'll be back soon..."
      }
  """
  def get_config do
    %{
      enabled: enabled?(),
      header: get_header(),
      subtext: get_subtext()
    }
  end
end
