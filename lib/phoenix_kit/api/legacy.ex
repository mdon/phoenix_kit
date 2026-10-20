defmodule PhoenixKit.API.Legacy do
  @moduledoc """
  Every name the machine API had before it was made module-neutral, in one
  place. The rest of `PhoenixKit.API` knows no module (a guard test fails when
  it spells one), so the day the deprecation window closes this file is
  deleted and nothing else changes.

  **This module is deleted in 3.0.0.** A client, a settings row or a module
  that still uses a name below has until then to move to the canonical one.

  What it holds:

    * the deprecated public paths, `/api/shop/v1` and `/mcp/shop`
      (`alias_paths/0`): `PhoenixKit.API.Paths` forwards them to the same
      plugs as the canonical `/api/public/v1` and `/mcp/public`, and the
      plugs mark every answer with `deprecation/0` and a `Link` to the
      canonical path;
    * the deprecated settings keys (`setting_fallback/1`): `PhoenixKit.API.Config`
      reads a limit from its new key and, when that holds no valid number, from
      the old one. Nothing deletes or migrates the old rows; the first save of
      Settings -> API writes the values in effect under the new keys.
  """

  # 2026-10-20T00:00:00Z, the day the neutral paths shipped, as an RFC 9745
  # `Deprecation` date (`@` and Unix seconds).
  @deprecation "@1792454400"

  # The public REST and MCP paths, as segments under the kit's URL prefix.
  @alias_paths [["api", "shop", "v1"], ["mcp", "shop"]]

  # New settings key => the key it replaces.
  @setting_fallbacks %{
    "api_public_token_rate_per_min" => "api_public_cart_rate_per_min",
    "api_public_new_rows_per_ip_hour" => "api_public_cart_rows_per_ip_hour",
    "api_public_new_rows_global_hour" => "api_public_cart_rows_global_hour"
  }

  @doc """
  The value of the `Deprecation` response header (RFC 9745) that every answer
  on a deprecated path carries.
  """
  @spec deprecation() :: String.t()
  def deprecation, do: @deprecation

  @doc """
  The deprecated public API paths, as lists of segments (the REST one, then the
  MCP one). Each is served by the plug of the canonical public path of its
  transport, and nothing publishes them: documents and headers name the
  canonical path only.
  """
  @spec alias_paths() :: [[String.t()]]
  def alias_paths, do: @alias_paths

  @doc """
  The deprecated settings key that `key` replaces, or `nil` when `key` replaced
  none. `PhoenixKit.API.Config.int/3` reads it when `key` holds no valid number.
  """
  @spec setting_fallback(String.t()) :: String.t() | nil
  def setting_fallback(key) when is_binary(key), do: Map.get(@setting_fallbacks, key)
end
