defmodule PhoenixKit.API.Canonical do
  @moduledoc """
  The canonical form of a tool's arguments, and the hash that binds a confirmation
  code, an approval and an idempotency key to a request.

  Canonical JSON: object keys sorted (atoms turned into strings), arrays in their
  order, scalars as `JSON.encode!/1` writes them. Two requests with the same
  arguments in a different key order hash the same; a different list order, value,
  type (`1` and `"1"`) or tool hashes differently. The caller passes the arguments
  **without** the control fields (`dry_run`, `confirm_token`, `idempotency_key`),
  so a confirming call, which adds a `confirm_token`, hashes like the preview call.

  `1` and `1.0` are different JSON numbers and hash differently; a client that
  changes how it writes a number between the preview and the confirmation gets
  `409 confirm_token_invalid`, which is safe.
  """

  @doc "The canonical JSON of `value` as iodata."
  @spec encode(term()) :: iodata()
  def encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ?:, encode(value)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  def encode(list) when is_list(list) do
    [?[, list |> Enum.map(&encode/1) |> Enum.intersperse(?,), ?]]
  end

  def encode(scalar), do: JSON.encode!(scalar)

  @doc """
  The SHA-256 (64 lowercase hex characters) of the tool name and the canonical form
  of `input`.
  """
  @spec hash(String.t(), term()) :: String.t()
  def hash(tool_name, input) when is_binary(tool_name) do
    :crypto.hash(:sha256, [tool_name, 0, encode(input)]) |> Base.encode16(case: :lower)
  end
end
