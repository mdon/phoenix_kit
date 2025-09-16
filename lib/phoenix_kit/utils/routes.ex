defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
  """

  def path(url_path) do
    if String.starts_with?(url_path, "/") do
      url_prefix = PhoenixKit.Config.get_url_prefix()

      if url_prefix === "/" do
        url_path
      else
        "#{url_prefix}#{url_path}"
      end
    else
      raise """
      Url path must start with "/".
      """
    end
  end

  @doc """
  Returns a full url with preconfigured prefix.

  This function automatically detects the correct URL from the running Phoenix
  application endpoint when possible, falling back to static configuration.
  This ensures that magic links and other email links work correctly in both
  development and production environments.
  """
  def url(url_path) do
    base_url = PhoenixKit.Config.get_dynamic_base_url()
    full_path = path(url_path)

    "#{base_url}#{full_path}"
  end
end
