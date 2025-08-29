defmodule PhoenixKit.Utils.PhoenixVersion do
  @moduledoc """
  Utilities for detecting and working with Phoenix framework versions.

  This module provides functions to detect the Phoenix version in use
  and determine compatibility strategies for different Phoenix versions,
  particularly for layout integration between v1.7- and v1.8+.

  ## Usage

      iex> PhoenixKit.Utils.PhoenixVersion.get_version()
      "1.8.2"
      
      iex> PhoenixKit.Utils.PhoenixVersion.get_strategy()
      :modern
      
      iex> PhoenixKit.Utils.PhoenixVersion.supports_function_components?()
      true

  ## Version Strategies

  - `:legacy` - Phoenix < 1.8.0, uses router-level layout configuration
  - `:modern` - Phoenix >= 1.8.0, supports function component layouts
  """

  @legacy_fallback_version "1.7.0"
  @modern_threshold_version "1.8.0"

  @doc """
  Gets the current Phoenix framework version as a string.

  Returns the version from the Phoenix application specification,
  or a fallback version if Phoenix is not found.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.get_version()
      "1.8.2"
  """
  @spec get_version() :: String.t()
  def get_version do
    case Application.spec(:phoenix) do
      nil ->
        @legacy_fallback_version

      spec ->
        spec
        |> Keyword.get(:vsn, @legacy_fallback_version)
        |> normalize_version()
    end
  end

  @doc """
  Gets the compatibility strategy for the current Phoenix version.

  Returns either `:legacy` for Phoenix < 1.8.0 or `:modern` for Phoenix >= 1.8.0.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.get_strategy()
      :modern
  """
  @spec get_strategy() :: :legacy | :modern
  def get_strategy do
    version = get_version()

    case Version.compare(version, @modern_threshold_version) do
      # Phoenix < 1.8.0
      :lt -> :legacy
      # Phoenix >= 1.8.0
      _ -> :modern
    end
  end

  @doc """
  Checks if the current Phoenix version supports function component layouts.

  Function component layouts were introduced in Phoenix 1.8.0.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.supports_function_components?()
      true
  """
  @spec supports_function_components?() :: boolean()
  def supports_function_components? do
    get_strategy() == :modern
  end

  @doc """
  Checks if the current Phoenix version requires legacy layout configuration.

  Legacy layout configuration is required for Phoenix < 1.8.0.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.requires_legacy_config?()
      false
  """
  @spec requires_legacy_config?() :: boolean()
  def requires_legacy_config? do
    get_strategy() == :legacy
  end

  @doc """
  Checks if a specific version string represents a modern Phoenix version.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.modern_version?("1.8.0")
      true
      
      iex> PhoenixKit.Utils.PhoenixVersion.modern_version?("1.7.14")
      false
  """
  @spec modern_version?(String.t()) :: boolean()
  def modern_version?(version_string) when is_binary(version_string) do
    normalized = normalize_version(version_string)

    case Version.compare(normalized, @modern_threshold_version) do
      :lt -> false
      _ -> true
    end
  rescue
    Version.InvalidVersionError -> false
  end

  @doc """
  Gets version information for debugging and diagnostics.

  Returns a map with detailed version information including the raw version
  from the application spec and the normalized version used for comparisons.

  ## Examples

      iex> PhoenixKit.Utils.PhoenixVersion.get_version_info()
      %{
        raw_version: '1.8.2',
        normalized_version: "1.8.2",
        strategy: :modern,
        supports_function_components: true,
        threshold_version: "1.8.0"
      }
  """
  @spec get_version_info() :: map()
  def get_version_info do
    raw_spec = Application.spec(:phoenix)
    raw_version = if raw_spec, do: Keyword.get(raw_spec, :vsn), else: nil
    normalized = get_version()
    strategy = get_strategy()

    %{
      raw_version: raw_version,
      normalized_version: normalized,
      strategy: strategy,
      supports_function_components: supports_function_components?(),
      requires_legacy_config: requires_legacy_config?(),
      threshold_version: @modern_threshold_version,
      fallback_version: @legacy_fallback_version
    }
  end

  ## Private Functions

  # Normalizes version from application spec (charlist or string) to string
  defp normalize_version(version) when is_list(version) do
    version
    |> to_string()
    |> String.trim()
  end

  defp normalize_version(version) when is_binary(version) do
    String.trim(version)
  end

  defp normalize_version(_), do: @legacy_fallback_version
end
