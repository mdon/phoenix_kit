defmodule PhoenixKit.Utils.Values do
  @moduledoc """
  Small value-handling helpers used across the workspace.
  """

  @doc """
  Returns `nil` for `nil` or blank-string inputs; passes non-blank
  strings through unchanged. Useful when reading query params, form
  values, or settings where empty string and `nil` should mean the
  same thing.

  Non-string values (e.g. a list from a `key[]=` query param) pass
  through untouched — the helper only collapses the empty string, it
  never raises on unexpected input.

      iex> PhoenixKit.Utils.Values.blank_to_nil(nil)
      nil
      iex> PhoenixKit.Utils.Values.blank_to_nil("")
      nil
      iex> PhoenixKit.Utils.Values.blank_to_nil("hello")
      "hello"
      iex> PhoenixKit.Utils.Values.blank_to_nil(["a", "b"])
      ["a", "b"]
  """
  @spec blank_to_nil(value) :: value | nil when value: term()
  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(v) when is_binary(v), do: v
  def blank_to_nil(v), do: v

  @doc """
  Like `blank_to_nil/1`, but trims whitespace before the blank check.

  Returns the trimmed string when there's content, `nil` otherwise.
  Use this for inputs where leading / trailing whitespace shouldn't
  count as "present" (HTML form values, URL query params that may
  carry stray whitespace, scraped IDs, etc.). When the value will
  already be normalised by the caller, prefer `blank_to_nil/1` to
  avoid the unnecessary `String.trim/1`.

  Non-string values (e.g. a list from a `key[]=` query param) yield
  `nil` — the helper treats anything that isn't a non-blank string as
  "not present" rather than raising on unexpected input.

      iex> PhoenixKit.Utils.Values.presence(nil)
      nil
      iex> PhoenixKit.Utils.Values.presence("   ")
      nil
      iex> PhoenixKit.Utils.Values.presence("  hello ")
      "hello"
      iex> PhoenixKit.Utils.Values.presence(["a", "b"])
      nil
  """
  @spec presence(term()) :: nil | String.t()
  def presence(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_), do: nil
end
