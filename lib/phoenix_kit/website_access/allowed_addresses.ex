defmodule PhoenixKit.WebsiteAccess.AllowedAddresses do
  @moduledoc """
  Addresses that walk past the gate and the redirect without a password —
  the office, the boss's home — one per line in a setting. Exact match on
  the visitor's address as core sees it (`PhoenixKit.Utils.IpAddress`).
  """

  alias PhoenixKit.Settings

  @key "website_access_allowed_addresses"

  def key, do: @key

  @spec list() :: [String.t()]
  def list do
    Settings.get_setting_cached(@key, "")
    |> to_string()
    |> String.split(~r/[\s,]+/, trim: true)
  end

  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(address) when is_binary(address) and address != "", do: address in list()
  def allowed?(_), do: false
end
