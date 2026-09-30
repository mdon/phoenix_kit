defmodule PhoenixKit.Utils.PublicAddress do
  @moduledoc """
  Whether an IP address is a globally routable unicast address — the only
  kind a server-side fetch of a user-supplied URL may connect to.

  Everything in the IANA special-purpose registries is refused: loopback,
  private (RFC 1918 and unique-local), link-local (which includes the cloud
  metadata address 169.254.169.254), carrier-grade NAT, "this network",
  documentation and benchmarking ranges, multicast, reserved space, and the
  IPv6 forms that smuggle an IPv4 address (IPv4-mapped, IPv4-compatible,
  NAT64, 6to4, Teredo). Listing what is *not* public is how the registries
  themselves are organised; an address in none of these ranges is public.
  """

  import Bitwise

  @type ip :: :inet.ip_address()

  @doc "Whether `ip` (a tuple or a string) is a public unicast address."
  @spec public?(ip() | String.t()) :: boolean()
  def public?(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, parsed} -> public?(parsed)
      {:error, _} -> false
    end
  end

  def public?({_, _, _, _} = ip), do: not Enum.any?(v4_blocked(), &in_range?(ip, &1))

  def public?({_, _, _, _, _, _, _, _} = ip) do
    case embedded_v4(ip) do
      {:ok, v4} -> public?(v4) and not Enum.any?(v6_blocked(), &in_range?(ip, &1))
      :none -> not Enum.any?(v6_blocked(), &in_range?(ip, &1))
    end
  end

  def public?(_ip), do: false

  @doc """
  Resolves `host` and returns `{:ok, ip}` — an address to connect to — only
  when EVERY address it resolves to is public, so a name with one public
  and one internal record cannot be used to reach the internal one.
  A literal IP is checked as it is.
  """
  @spec resolve_public(String.t()) :: {:ok, ip()} | {:error, :blocked_host | :nxdomain}
  def resolve_public(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    addresses =
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, ip} -> [ip]
        {:error, _} -> lookup(host)
      end

    cond do
      addresses == [] -> {:error, :nxdomain}
      Enum.all?(addresses, &public?/1) -> {:ok, prefer_v4(addresses)}
      true -> {:error, :blocked_host}
    end
  end

  defp lookup(host) do
    charlist = String.to_charlist(host)

    Enum.flat_map([:inet, :inet6], fn family ->
      case :inet.getaddrs(charlist, family) do
        {:ok, ips} -> ips
        {:error, _} -> []
      end
    end)
  end

  defp prefer_v4(addresses), do: Enum.find(addresses, hd(addresses), &(tuple_size(&1) == 4))

  # An IPv6 address that carries an IPv4 one: mapped (::ffff:a.b.c.d),
  # compatible (::a.b.c.d), NAT64 (64:ff9b::a.b.c.d). The embedded address
  # must itself be public.
  defp embedded_v4({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: {:ok, v4_of(a, b)}
  defp embedded_v4({0, 0, 0, 0, 0, 0, a, b}) when a != 0 or b > 1, do: {:ok, v4_of(a, b)}
  defp embedded_v4({0x64, 0xFF9B, 0, 0, 0, 0, a, b}), do: {:ok, v4_of(a, b)}
  defp embedded_v4(_ip), do: :none

  defp v4_of(a, b), do: {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}

  # {network, prefix length}
  defp v4_blocked do
    [
      {{0, 0, 0, 0}, 8},
      {{10, 0, 0, 0}, 8},
      {{100, 64, 0, 0}, 10},
      {{127, 0, 0, 0}, 8},
      {{169, 254, 0, 0}, 16},
      {{172, 16, 0, 0}, 12},
      {{192, 0, 0, 0}, 24},
      {{192, 0, 2, 0}, 24},
      {{192, 88, 99, 0}, 24},
      {{192, 168, 0, 0}, 16},
      {{198, 18, 0, 0}, 15},
      {{198, 51, 100, 0}, 24},
      {{203, 0, 113, 0}, 24},
      {{224, 0, 0, 0}, 4},
      {{240, 0, 0, 0}, 4}
    ]
  end

  defp v6_blocked do
    [
      # unspecified, loopback, IPv4-compatible
      {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
      # IPv4-mapped
      {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, 96},
      # NAT64 (well-known and local-use)
      {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
      {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
      # discard-only
      {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
      # IETF protocol assignments (Teredo, benchmarking, ORCHID…)
      {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
      # documentation
      {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
      {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20},
      # 6to4
      {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
      # unique-local (includes the AWS IMDS fd00:ec2::254)
      {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
      # link-local and the deprecated site-local
      {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
      {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
      # multicast
      {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
    ]
  end

  defp in_range?(ip, {network, prefix}) when tuple_size(ip) == tuple_size(network) do
    bits = if tuple_size(ip) == 4, do: 8, else: 16

    to_int(ip, bits) >>> (tuple_size(ip) * bits - prefix) ==
      to_int(network, bits) >>> (tuple_size(ip) * bits - prefix)
  end

  defp in_range?(_ip, _range), do: false

  defp to_int(tuple, bits),
    do: tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< bits) + part end)
end
