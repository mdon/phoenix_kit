defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  URL utilities for PhoenixKit.

  ## Core Functions

  - `path/1` - Returns an url path with preconfigured prefix.
  - `url/1` - Returns a full url with preconfigured prefix.
  """

  @doc """
  Returns an url path with preconfigured prefix.
  """
  def path(url_path) do
    if String.starts_with?(url_path, "/") do
      url_prefix = PhoenixKit.Config.get_url_prefix()
      "#{url_prefix}#{url_path}"
    else
      raise """
      Url path must start with "/".
      """
    end
  end

  @doc """
  Returns a full url with preconfigured prefix.
  """
  def url(url_path) do
    base_url = PhoenixKit.Config.get_base_url()
    full_path = path(url_path)

    "#{base_url}#{full_path}"
  end
end
