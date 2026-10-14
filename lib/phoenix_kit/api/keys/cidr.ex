defmodule PhoenixKit.API.Keys.CIDR do
  @moduledoc """
  The IP allow-list of an API key: a list of CIDR blocks stored as text.

  An entry is `address/prefix_length` or a bare address (a single host). The
  text is split on `/`, the address is parsed with `:inet.parse_strict_address/1`
  and the prefix length must fit the address family (0-32 for IPv4, 0-128 for
  IPv6). A client address is allowed when it falls inside any block of its own
  family; an IPv4-mapped IPv6 client (`::ffff:203.0.113.7`) counts as IPv4.

  `parse_strict_address/1` is `:inet.parse_address/1` without its shorthand forms
  (`"10.1"` would be read as `10.0.0.1`), so only addresses written out in full
  are accepted.
  """

  import Bitwise

  @type block :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  Validates an entry and returns it in canonical text form.

      iex> PhoenixKit.API.Keys.CIDR.normalize("203.0.113.7")
      {:ok, "203.0.113.7/32"}

      iex> PhoenixKit.API.Keys.CIDR.normalize("2001:DB8::/32")
      {:ok, "2001:db8::/32"}

      iex> PhoenixKit.API.Keys.CIDR.normalize("10.0.0.0/33")
      :error
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(text) do
    case parse(text) do
      {:ok, {address, bits}} -> {:ok, "#{:inet.ntoa(address)}/#{bits}"}
      :error -> :error
    end
  end

  @doc """
  Normalises a list of entries.

  Returns `{:ok, normalised}` or `{:error, invalid_entries}` naming every entry
  that did not parse.
  """
  @spec normalize_all([term()]) :: {:ok, [String.t()]} | {:error, [term()]}
  def normalize_all(entries) when is_list(entries) do
    results = Enum.map(entries, &{&1, normalize(&1)})

    case for({entry, :error} <- results, do: entry) do
      [] -> {:ok, for({_, {:ok, text}} <- results, do: text) |> Enum.uniq()}
      invalid -> {:error, invalid}
    end
  end

  @doc "Whether `client_ip` (text) falls inside any block of `entries` (CIDR text)."
  @spec allowed?([String.t()], String.t() | nil) :: boolean()
  def allowed?(entries, client_ip) when is_list(entries) and is_binary(client_ip) do
    case parse_address(client_ip) do
      {:ok, address} ->
        Enum.any?(entries, &entry_contains?(&1, address))

      :error ->
        false
    end
  end

  def allowed?(_entries, _client_ip), do: false

  @doc "Whether `address` is inside `block`. Different families never match."
  @spec contains?(block(), :inet.ip_address()) :: boolean()
  def contains?({network, bits}, address) do
    case {family(network), family(address)} do
      {same, same} ->
        shift = width(same) - bits
        bsr(to_integer(network), shift) == bsr(to_integer(address), shift)

      _ ->
        false
    end
  end

  defp entry_contains?(entry, address) do
    case parse(entry) do
      {:ok, block} -> contains?(block, address)
      :error -> false
    end
  end

  defp parse(text) when is_binary(text) do
    with [address_text | rest] <- String.split(String.trim(text), "/"),
         {:ok, address} <- parse_address(address_text),
         {:ok, bits} <- prefix_length(rest, address) do
      {:ok, {address, bits}}
    else
      _ -> :error
    end
  end

  defp parse(_), do: :error

  defp parse_address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, address} -> {:ok, unmap(address)}
      {:error, _} -> :error
    end
  end

  defp prefix_length([], address), do: {:ok, width(family(address))}

  defp prefix_length([length_text], address) do
    case Integer.parse(length_text) do
      {bits, ""} when bits >= 0 ->
        if bits <= width(family(address)), do: {:ok, bits}, else: :error

      _ ->
        :error
    end
  end

  defp prefix_length(_, _address), do: :error

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp unmap(address), do: address

  defp family(address) when tuple_size(address) == 4, do: :ipv4
  defp family(address) when tuple_size(address) == 8, do: :ipv6

  defp width(:ipv4), do: 32
  defp width(:ipv6), do: 128

  defp to_integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp to_integer(address) when tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.reduce(0, fn group, acc -> acc <<< 16 ||| group end)
  end
end
