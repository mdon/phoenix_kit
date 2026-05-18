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
end
