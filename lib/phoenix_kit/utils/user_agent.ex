defmodule PhoenixKit.Utils.UserAgent do
  @moduledoc """
  Deliberately small, allocation-light User-Agent sniffing.

  Enough to make a device recognisable in UI/email copy ("Chrome on
  macOS"), not a UA-parsing library. Shared by the QR login confirm
  screen and the new-login security alert.
  """

  @doc """
  Best-effort browser name from a raw User-Agent string.

  Returns `nil` for `nil` input or an unrecognized string.
  """
  @spec browser(String.t() | nil) :: String.t() | nil
  def browser(nil), do: nil

  def browser(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Edg/") -> "Edge"
      String.contains?(ua, "OPR/") or String.contains?(ua, "Opera") -> "Opera"
      String.contains?(ua, "Firefox") -> "Firefox"
      String.contains?(ua, "Chrome") -> "Chrome"
      String.contains?(ua, "Safari") -> "Safari"
      true -> nil
    end
  end

  @doc """
  Best-effort OS name from a raw User-Agent string.

  Returns `nil` for `nil` input or an unrecognized string.
  """
  @spec os(String.t() | nil) :: String.t() | nil
  def os(nil), do: nil

  def os(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Windows") -> "Windows"
      String.contains?(ua, "iPhone") or String.contains?(ua, "iPad") -> "iOS"
      String.contains?(ua, "Mac OS X") or String.contains?(ua, "Macintosh") -> "macOS"
      String.contains?(ua, "Android") -> "Android"
      String.contains?(ua, "Linux") -> "Linux"
      true -> nil
    end
  end
end
