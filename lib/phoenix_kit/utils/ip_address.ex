defmodule PhoenixKit.Utils.IpAddress do
  @moduledoc """
  Utilities for extracting and formatting IP addresses.

  Supports both IPv4 and IPv6 addresses with proper error handling.
  Prevents Protocol.UndefinedError when working with IPv6 tuples.

  ## Usage

  Extract from LiveView socket:
      ip = PhoenixKit.Utils.IpAddress.extract_from_socket(socket)

  Extract from Plug.Conn:
      ip = PhoenixKit.Utils.IpAddress.extract_from_conn(conn)

  Extract from peer_data directly:
      ip = PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {192, 168, 1, 1}})

  ## Examples

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {192, 168, 1, 1}})
      "192.168.1.1"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {8193, 3512, 1, 0, 0, 0, 0, 1}})
      "8193:3512:1:0:0:0:0:1"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(nil)
      "unknown"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{})
      "unknown"
  """

  @doc """
  Extracts IP address from peer_data map.

  Handles both IPv4 (4-tuple) and IPv6 (8-tuple) addresses.
  Returns "unknown" for nil, invalid, or missing data.

  ## Parameters

  - `peer_data`: Map with `:address` key containing IP tuple, or nil

  ## Returns

  - IPv4 as "a.b.c.d" string
  - IPv6 as "a:b:c:d:e:f:g:h" string
  - "unknown" for invalid or missing data
  """
  def extract_ip_address(nil), do: "unknown"

  def extract_ip_address(%{address: {a, b, c, d}})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  def extract_ip_address(%{address: {a, b, c, d, e, f, g, h}})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
             is_integer(e) and is_integer(f) and is_integer(g) and is_integer(h) do
    "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  end

  def extract_ip_address(_), do: "unknown"

  @doc """
  Extracts the visitor's IP address from a `Plug.Conn`.

  Proxy-aware: delegates to `client_address/1`, which reads `x-forwarded-for`
  / `x-real-ip` when `conn.remote_ip` is a loopback or private address (a
  reverse proxy on the same box or network), and trusts a public
  `conn.remote_ip` as-is.

  ## Parameters

  - `conn`: Plug.Conn struct

  ## Returns

  - IP address string or "unknown" (never nil — callers that need to tell
    "known" apart from "unknown" should call `client_address/1` directly)
  """
  def extract_from_conn(conn) do
    client_address(conn) || "unknown"
  end

  @doc """
  The visitor's address as best a site behind a reverse proxy can tell.

  `extract_from_conn/1` answers the TCP peer, which behind nginx (or in a
  container) is the proxy's own address for every visitor. This one takes
  `conn.remote_ip` (which a host's RemoteIp plug already rewrites) and, when
  that is a loopback or private address — a proxy on the same box or the
  same network — the LAST entry of `x-forwarded-for`, the one that proxy
  appended (a visitor can send their own header; they cannot control what
  nginx appends after it), then `x-real-ip`. A public `remote_ip` is trusted
  as is. Returns nil when nothing is known.

      iex> conn = %Plug.Conn{remote_ip: {127, 0, 0, 1}, req_headers: [{"x-forwarded-for", "9.9.9.9, 203.0.113.7"}]}
      iex> PhoenixKit.Utils.IpAddress.client_address(conn)
      "203.0.113.7"
  """
  @spec client_address(Plug.Conn.t()) :: String.t() | nil
  def client_address(%Plug.Conn{remote_ip: ip} = conn) do
    if local?(ip) do
      forwarded_for(conn) || real_ip(conn) || format(ip)
    else
      format(ip)
    end
  end

  @doc """
  The visitor's address as a LiveView socket knows it — or nil when the
  socket cannot tell.

  From the connect info the endpoint passes: a public `:peer_data` address
  is the visitor; a loopback or private one is a proxy, and only the
  forwarded address in `:x_headers` (`x-forwarded-for`, `x-real-ip`) names
  the visitor then. An endpoint that passes no `:x_headers` — core's
  installed endpoint passes `:peer_data` only — leaves a proxied socket
  with no answer, and nil is that answer: the caller must not treat the
  proxy as the visitor.
  """
  @spec client_address_from_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def client_address_from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: ip} when is_tuple(ip) ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        conn = %Plug.Conn{remote_ip: ip, req_headers: headers}

        if local?(ip), do: forwarded_for(conn) || real_ip(conn), else: format(ip)

      _ ->
        nil
    end
  rescue
    # Connect info exists on a root socket during mount only; a nested
    # LiveView, or a call after mount, gets the same answer as a socket
    # that cannot tell.
    RuntimeError -> nil
  end

  # Every instance of the header, in order, as one list — a proxy that adds
  # its own header line rather than appending to the visitor's still puts
  # the real address last.
  defp forwarded_for(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        nil

      values ->
        values |> Enum.join(",") |> String.split(",") |> List.last() |> String.trim() |> parse()
    end
  end

  defp real_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-real-ip") do
      [value | _] -> value |> String.trim() |> parse()
      [] -> nil
    end
  end

  # Only something `:inet` parses is an address; a header full of junk is
  # nobody's address.
  defp parse(""), do: nil

  defp parse(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, tuple} -> format(tuple)
      _ -> nil
    end
  end

  defp format(nil), do: nil

  defp format(tuple) when is_tuple(tuple) do
    case :inet.ntoa(tuple) do
      {:error, _} -> nil
      chars -> List.to_string(chars)
    end
  end

  defp local?({127, _, _, _}), do: true
  defp local?({10, _, _, _}), do: true
  defp local?({192, 168, _, _}), do: true
  defp local?({172, b, _, _}) when b in 16..31, do: true
  defp local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local?({0, 0, 0, 0, 0, 65_535, _, _} = v4_mapped), do: local?(unmap(v4_mapped))
  defp local?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp local?(_), do: false

  defp unmap({0, 0, 0, 0, 0, 65_535, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  @doc """
  Extracts the visitor's IP address from a Phoenix.LiveView socket.

  Proxy-aware: delegates to `client_address_from_socket/1`, which reads the
  connect info's `:x_headers` when the socket's `:peer_data` is a loopback
  or private address, and trusts a public `:peer_data` address as-is.

  ## Parameters

  - `socket`: Phoenix.LiveView.Socket struct

  ## Returns

  - IP address string or "unknown" (never nil — callers that need to tell
    "known" apart from "unknown" should call `client_address_from_socket/1`
    directly). "unknown" also covers a host endpoint that never declared
    `:peer_data` in the socket's `connect_info` — see that function's docs.
  """
  def extract_from_socket(socket) do
    client_address_from_socket(socket) || "unknown"
  end
end
