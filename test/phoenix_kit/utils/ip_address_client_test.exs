defmodule PhoenixKit.Utils.IpAddressClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.IpAddress

  defp conn(ip, headers \\ []), do: %Plug.Conn{remote_ip: ip, req_headers: headers}

  test "a public peer is the address, whatever the headers say" do
    assert IpAddress.client_address(conn({203, 0, 113, 7})) == "203.0.113.7"

    assert IpAddress.client_address(conn({203, 0, 113, 7}, [{"x-forwarded-for", "1.1.1.1"}])) ==
             "203.0.113.7"
  end

  test "behind a local proxy the LAST forwarded entry wins" do
    headers = [{"x-forwarded-for", "9.9.9.9, 203.0.113.7"}]
    assert IpAddress.client_address(conn({127, 0, 0, 1}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({172, 18, 0, 1}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({10, 0, 0, 5}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({0, 0, 0, 0, 0, 0, 0, 1}, headers)) == "203.0.113.7"
  end

  test "two header lines are one list; the last entry still wins" do
    headers = [{"x-forwarded-for", "203.0.113.10"}, {"x-forwarded-for", "198.51.100.20"}]
    assert IpAddress.client_address(conn({127, 0, 0, 1}, headers)) == "198.51.100.20"
  end

  test "x-real-ip is the fallback; junk is nobody" do
    assert IpAddress.client_address(conn({127, 0, 0, 1}, [{"x-real-ip", "203.0.113.9"}])) ==
             "203.0.113.9"

    assert IpAddress.client_address(conn({127, 0, 0, 1}, [{"x-forwarded-for", "not an ip"}])) ==
             "127.0.0.1"

    assert IpAddress.client_address(conn({127, 0, 0, 1})) == "127.0.0.1"
  end

  test "IPv6 is formatted the usual way" do
    assert IpAddress.client_address(conn({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})) == "2001:db8::1"
  end
end
