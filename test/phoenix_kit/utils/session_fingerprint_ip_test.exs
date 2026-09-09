defmodule PhoenixKit.Utils.SessionFingerprintIpTest do
  @moduledoc """
  `SessionFingerprint.get_ip_address/1` used to trust `x-forwarded-for` /
  `x-real-ip` unconditionally and take the FIRST `x-forwarded-for` entry —
  both client-controlled. Anyone could spoof the IP this module records
  (and that session-hijack detection and "new device" login alerts compare
  against) with a plain header, proxy or no proxy. It now defers to
  `IpAddress.client_address/1`, which only trusts a forwarded header when
  `conn.remote_ip` is itself a loopback/private address, and only the LAST
  entry.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.SessionFingerprint

  defp conn(remote_ip, headers \\ []) do
    Enum.reduce(headers, %Plug.Conn{remote_ip: remote_ip}, fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
  end

  test "a direct public connection cannot be spoofed via x-forwarded-for" do
    assert SessionFingerprint.get_ip_address(
             conn({203, 0, 113, 7}, [
               {"x-forwarded-for", "6.6.6.6"}
             ])
           ) == "203.0.113.7"
  end

  test "a direct public connection cannot be spoofed via x-real-ip" do
    assert SessionFingerprint.get_ip_address(
             conn({203, 0, 113, 7}, [
               {"x-real-ip", "6.6.6.6"}
             ])
           ) == "203.0.113.7"
  end

  test "behind a real local proxy, the LAST forwarded entry is trusted" do
    headers = [{"x-forwarded-for", "6.6.6.6, 203.0.113.7"}]
    assert SessionFingerprint.get_ip_address(conn({127, 0, 0, 1}, headers)) == "203.0.113.7"
  end

  test "no headers, no proxy: the raw peer address" do
    assert SessionFingerprint.get_ip_address(conn({203, 0, 113, 7})) == "203.0.113.7"
  end
end
