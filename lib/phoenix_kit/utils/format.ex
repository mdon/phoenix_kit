defmodule PhoenixKit.Utils.Format do
  @moduledoc """
  Workspace-shared formatting helpers for numeric / size values.
  """

  @doc """
  Formats a byte count as a human-readable size string.

  Accepts an integer, `Decimal`, or `nil`. Returns the `:unknown` option
  string for `nil` (or any unrecognised input) and rounds to `:decimals`
  decimal places for the chosen unit. The unit auto-scales to B / KB /
  MB / GB based on the size.

  ## Options

  - `:decimals` — decimal places for KB/MB/GB output. Default `1`.
  - `:unknown` — string returned for `nil` or unrecognised inputs.
    Default `"Unknown"`. Pass `"0 B"` to mimic the file-picker shape.
  - `:base` — `1024` (binary, default) or `1000` (decimal/SI). Some
    media-browser surfaces use the decimal convention to match what
    operating systems show; everything else defaults to the binary
    convention common in dev tooling.

  ## Examples

      iex> PhoenixKit.Utils.Format.bytes(0)
      "0 B"

      iex> PhoenixKit.Utils.Format.bytes(1500)
      "1.5 KB"

      iex> PhoenixKit.Utils.Format.bytes(1_500_000, decimals: 2)
      "1.43 MB"

      iex> PhoenixKit.Utils.Format.bytes(1_500_000, base: 1000, decimals: 2)
      "1.5 MB"

      iex> PhoenixKit.Utils.Format.bytes(nil, unknown: "0 B")
      "0 B"
  """
  @spec bytes(integer() | Decimal.t() | nil, keyword()) :: String.t()
  def bytes(value, opts \\ [])

  def bytes(nil, opts), do: Keyword.get(opts, :unknown, "Unknown")
  def bytes(0, _opts), do: "0 B"

  def bytes(%Decimal{} = d, opts) do
    d |> Decimal.to_integer() |> bytes(opts)
  end

  def bytes(n, opts) when is_number(n) and n > 0 do
    decimals = Keyword.get(opts, :decimals, 1)
    {kb, mb, gb} = unit_thresholds(Keyword.get(opts, :base, 1024))

    cond do
      n >= gb -> "#{Float.round(n / gb, decimals)} GB"
      n >= mb -> "#{Float.round(n / mb, decimals)} MB"
      n >= kb -> "#{Float.round(n / kb, decimals)} KB"
      true -> "#{n} B"
    end
  end

  def bytes(_, opts), do: Keyword.get(opts, :unknown, "Unknown")

  defp unit_thresholds(1000), do: {1_000, 1_000_000, 1_000_000_000}
  defp unit_thresholds(_), do: {1024, 1_048_576, 1_073_741_824}
end
