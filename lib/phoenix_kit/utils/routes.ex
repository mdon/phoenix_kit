defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
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

  def url(url_path) do
    base_url = PhoenixKit.Config.get_base_url()
    full_path = path(url_path)

    "#{base_url}#{full_path}"
  end
end
