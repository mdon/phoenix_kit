defmodule PhoenixKit.Utils.Values do
  @moduledoc """
  Small value-handling helpers used across the workspace.
  """

  @doc """
  Returns `nil` for `nil` or blank-string inputs; passes non-blank
  strings through unchanged. Useful when reading query params, form
  values, or settings where empty string and `nil` should mean the
  same thing.

      iex> PhoenixKit.Utils.Values.blank_to_nil(nil)
      nil
      iex> PhoenixKit.Utils.Values.blank_to_nil("")
      nil
      iex> PhoenixKit.Utils.Values.blank_to_nil("hello")
      "hello"
  """
  @spec blank_to_nil(nil | String.t()) :: nil | String.t()
  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(v) when is_binary(v), do: v

  @doc """
  Like `blank_to_nil/1`, but trims whitespace before the blank check.

  Returns the trimmed string when there's content, `nil` otherwise.
  Use this for inputs where leading / trailing whitespace shouldn't
  count as "present" (HTML form values, URL query params that may
  carry stray whitespace, scraped IDs, etc.). When the value will
  already be normalised by the caller, prefer `blank_to_nil/1` to
  avoid the unnecessary `String.trim/1`.

      iex> PhoenixKit.Utils.Values.presence(nil)
      nil
      iex> PhoenixKit.Utils.Values.presence("   ")
      nil
      iex> PhoenixKit.Utils.Values.presence("  hello ")
      "hello"
  """
  @spec presence(nil | String.t()) :: nil | String.t()
  def presence(nil), do: nil

  def presence(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
