defmodule PhoenixKit.Utils.Number do
  @moduledoc """
  Number formatting and parsing utilities for PhoenixKit.

  Formatting: thousand separators, abbreviations, percentages. Parsing:
  `parse_decimal/2` turns what a person typed into a form field ("2,5",
  "1 234.56") into a `Decimal` — pair it with
  `PhoenixKitWeb.Components.Core.DecimalInput.decimal_input/1`.
  """

  @doc """
  Formats a number with thousand separators.

  ## Examples

      iex> PhoenixKit.Utils.Number.format(1234567)
      "1,234,567"

      iex> PhoenixKit.Utils.Number.format(0)
      "0"

      iex> PhoenixKit.Utils.Number.format(nil)
      "0"
  """
  @spec format(integer() | nil) :: String.t()
  def format(number) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  def format(_number), do: "0"

  @doc """
  Formats a number with abbreviations (K, M, B).

  ## Examples

      iex> PhoenixKit.Utils.Number.format_short(1_234_567)
      "1.2M"

      iex> PhoenixKit.Utils.Number.format_short(5_432)
      "5.4K"

      iex> PhoenixKit.Utils.Number.format_short(123)
      "123"
  """
  @spec format_short(integer() | nil) :: String.t()
  def format_short(number) when is_integer(number) do
    cond do
      number >= 1_000_000_000 ->
        "#{Float.round(number / 1_000_000_000, 1)}B"

      number >= 1_000_000 ->
        "#{Float.round(number / 1_000_000, 1)}M"

      number >= 1_000 ->
        "#{Float.round(number / 1_000, 1)}K"

      true ->
        to_string(number)
    end
  end

  def format_short(_number), do: "0"

  @doc """
  Formats a number as a percentage.

  ## Examples

      iex> PhoenixKit.Utils.Number.format_percentage(95.5)
      "95.5%"

      iex> PhoenixKit.Utils.Number.format_percentage(100)
      "100%"

      iex> PhoenixKit.Utils.Number.format_percentage(nil)
      "0%"
  """
  @spec format_percentage(float() | integer() | nil) :: String.t()
  def format_percentage(rate) when is_float(rate) do
    "#{:erlang.float_to_binary(rate, decimals: 1)}%"
  end

  def format_percentage(rate) when is_integer(rate) do
    "#{rate}%"
  end

  def format_percentage(_), do: "0%"

  # Ten to the twelfth: wide enough for any quantity, price or measurement a
  # form takes, narrow enough that a pasted "1e1000000"-class string never
  # reaches arithmetic. `parse_decimal/2` rejects anything at or above it.
  @magnitude_ceiling Decimal.new("1000000000000")

  @doc """
  Parses a number a person typed into a form field — the counterpart of
  `PhoenixKitWeb.Components.Core.DecimalInput.decimal_input/1`.

  Keyboards in most of Europe produce a decimal COMMA, browsers and
  `Decimal.parse/1` want a dot, and `Decimal.parse/1` alone returns
  whatever prefix it could read (`"2,5"` silently became `2`). This
  function takes the text as a person meant it and returns a normalized
  `Decimal` or a reason:

    * a dot or a comma is the decimal point (`"2.5"`, `"2,5"`, `",5"`);
    * spaces (no-break and thin spaces too) are thousands grouping and are
      dropped (`"1 234,56"`);
    * with both a dot and a comma present, the LAST one is the decimal
      point and the other is grouping (`"1.234,56"`, `"1,234.56"`);
    * one kind repeated is grouping (`"1,234,567"`);
    * an optional leading sign; nothing else — exponents (`"1e9"`), `NaN`,
      `Infinity`, hex, stray letters are all `{:error, :invalid}`;
    * blank (or `nil`) is `{:error, :empty}`, so a caller can tell "left
      empty" from "typed garbage";
    * integers, floats and decimals pass straight through as a `Decimal`.

  The result is normalized (`"2.500"` → `2.5`, never an exponent form).

  ## Options

    * `:min` / `:max` — any number shape (`0`, `"0.25"`, `Decimal`); a value
      outside them is `{:error, :below_min}` / `{:error, :above_max}`,
      never clamped. A magnitude of 10¹² or more is `{:error, :above_max}`
      even without `:max`.

  ## Examples

      iex> PhoenixKit.Utils.Number.parse_decimal("2,5")
      {:ok, Decimal.new("2.5")}

      iex> PhoenixKit.Utils.Number.parse_decimal("1 234,56")
      {:ok, Decimal.new("1234.56")}

      iex> PhoenixKit.Utils.Number.parse_decimal("")
      {:error, :empty}

      iex> PhoenixKit.Utils.Number.parse_decimal("1e9")
      {:error, :invalid}

      iex> PhoenixKit.Utils.Number.parse_decimal("-1", min: 0)
      {:error, :below_min}
  """
  @type parse_error :: :empty | :invalid | :below_min | :above_max
  @spec parse_decimal(term(), keyword()) :: {:ok, Decimal.t()} | {:error, parse_error()}
  def parse_decimal(raw, opts \\ [])

  def parse_decimal(nil, _opts), do: {:error, :empty}

  def parse_decimal(raw, opts) when is_binary(raw) do
    with {:ok, normalized} <- normalize_decimal_text(raw),
         true <- Regex.match?(~r/^[+-]?(\d+(\.\d*)?|\.\d+)$/, normalized) || :invalid,
         {decimal, ""} <- Decimal.parse(normalized) do
      bound(Decimal.normalize(decimal), opts)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def parse_decimal(%Decimal{} = decimal, opts) do
    if Decimal.nan?(decimal) or Decimal.inf?(decimal),
      do: {:error, :invalid},
      else: bound(Decimal.normalize(decimal), opts)
  end

  def parse_decimal(n, opts) when is_integer(n), do: bound(Decimal.new(n), opts)
  def parse_decimal(n, opts) when is_float(n), do: parse_decimal(Decimal.from_float(n), opts)
  def parse_decimal(_other, _opts), do: {:error, :invalid}

  @doc """
  Same as `parse_decimal/2`, returning the `Decimal` or raising
  `ArgumentError` with the reason.
  """
  @spec parse_decimal!(term(), keyword()) :: Decimal.t()
  def parse_decimal!(raw, opts \\ []) do
    case parse_decimal(raw, opts) do
      {:ok, decimal} -> decimal
      {:error, reason} -> raise ArgumentError, "not a decimal (#{reason}): #{inspect(raw)}"
    end
  end

  @doc """
  Renders a number the way `decimal_input/1` shows it: a normalized plain
  string (`2.5`, `1000`, never `1E+3` or `2.500`), `""` for `nil`, and a
  binary unchanged — so the raw text a person typed round-trips through a
  re-render exactly as typed.

  ## Examples

      iex> PhoenixKit.Utils.Number.format_decimal(Decimal.new("2.500"))
      "2.5"

      iex> PhoenixKit.Utils.Number.format_decimal(nil)
      ""

      iex> PhoenixKit.Utils.Number.format_decimal("2,5")
      "2,5"
  """
  @spec format_decimal(term()) :: String.t()
  def format_decimal(nil), do: ""
  def format_decimal(text) when is_binary(text), do: text
  def format_decimal(%Decimal{} = d), do: Decimal.to_string(Decimal.normalize(d), :normal)
  def format_decimal(n) when is_integer(n), do: Integer.to_string(n)
  def format_decimal(n) when is_float(n), do: format_decimal(Decimal.from_float(n))
  def format_decimal(other), do: to_string(other)

  # Whitespace of every kind (ASCII, no-break, thin, narrow no-break) is
  # grouping; then the separators are resolved as documented above. Returns
  # the text with a single dot as the decimal point, or `{:error, :invalid}`
  # when a separator taken as grouping does not sit between 3-digit groups
  # ("2..5", "1,23,4") — that is a typo, not a number.
  defp normalize_decimal_text(raw) do
    text = String.replace(raw, ~r/[\s\x{00A0}\x{2009}\x{202F}]/u, "")

    if text == "" do
      {:error, :empty}
    else
      dots = count_char(text, ".")
      commas = count_char(text, ",")

      cond do
        dots > 0 and commas > 0 ->
          split_mixed(text)

        commas > 1 ->
          ungroup(text, ",")

        dots > 1 ->
          ungroup(text, ".")

        true ->
          {:ok, String.replace(text, ",", ".")}
      end
    end
  end

  # Both kinds present: the last separator typed is the decimal point, the
  # other one must be valid grouping on the integer part.
  defp split_mixed(text) do
    {group, point} =
      if last_index(text, ".") > last_index(text, ","), do: {",", "."}, else: {".", ","}

    case String.split(text, point) do
      [int, frac] -> with {:ok, int} <- ungroup(int, group), do: {:ok, int <> "." <> frac}
      _ -> {:error, :invalid}
    end
  end

  # "1,234,567" → "1234567"; anything but 1–3 leading digits followed by
  # groups of exactly three is not grouping.
  defp ungroup(text, sep) do
    case String.split(text, sep) do
      [head | groups] when groups != [] ->
        if Regex.match?(~r/^[+-]?\d{1,3}$/, head) and
             Enum.all?(groups, &Regex.match?(~r/^\d{3}$/, &1)),
           do: {:ok, String.replace(text, sep, "")},
           else: {:error, :invalid}

      _ ->
        {:ok, text}
    end
  end

  defp count_char(text, char), do: text |> String.graphemes() |> Enum.count(&(&1 == char))

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> -1
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp bound(decimal, opts) do
    min = opts[:min] && to_decimal!(opts[:min], :min)
    max = opts[:max] && to_decimal!(opts[:max], :max)

    cond do
      min && Decimal.lt?(decimal, min) -> {:error, :below_min}
      max && Decimal.gt?(decimal, max) -> {:error, :above_max}
      Decimal.gt?(Decimal.abs(decimal), @magnitude_ceiling) -> {:error, :above_max}
      Decimal.equal?(Decimal.abs(decimal), @magnitude_ceiling) -> {:error, :above_max}
      true -> {:ok, decimal}
    end
  end

  defp to_decimal!(%Decimal{} = d, _opt), do: d
  defp to_decimal!(n, _opt) when is_integer(n), do: Decimal.new(n)
  defp to_decimal!(n, _opt) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal!(text, opt) when is_binary(text) do
    case Decimal.parse(String.trim(text)) do
      {d, ""} -> d
      _ -> raise ArgumentError, "parse_decimal #{opt}: not a number: #{inspect(text)}"
    end
  end

  defp to_decimal!(other, opt),
    do: raise(ArgumentError, "parse_decimal #{opt}: not a number: #{inspect(other)}")
end
