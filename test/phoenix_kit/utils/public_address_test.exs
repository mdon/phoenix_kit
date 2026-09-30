defmodule PhoenixKit.Utils.PublicAddressTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.PublicAddress

  test "globally routable unicast addresses are public" do
    for ip <- ~w(1.1.1.1 8.8.8.8 93.184.216.34 2606:4700:4700::1111 2a00:1450:4001:80b::200e) do
      assert PublicAddress.public?(ip), ip
    end
  end

  test "everything special-purpose is not" do
    for ip <-
          ~w(0.0.0.0 0.1.2.3 10.0.0.1 100.64.0.1 127.0.0.1 127.9.9.9 169.254.169.254
             172.16.0.1 172.31.255.255 192.0.0.1 192.0.2.10 192.168.1.1 198.18.0.1
             198.51.100.7 203.0.113.9 224.0.0.1 239.255.255.250 240.0.0.1 255.255.255.255
             :: ::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:169.254.169.254 ::127.0.0.1
             64:ff9b::a00:1 64:ff9b::7f00:1 2001:db8::1 2002:c000:204::1 2001::1
             fc00::1 fd00:ec2::254 fe80::1 fec0::1 ff02::1 not-an-ip) do
      refute PublicAddress.public?(ip), ip
    end
  end

  test "an IPv6 form carrying an IPv4 address is refused even when that IPv4 is public" do
    # Stricter than necessary on purpose: a fetch never needs these forms.
    refute PublicAddress.public?("::ffff:8.8.8.8")
  end

  test "resolve_public refuses a host with any internal address, and literal IPs are checked" do
    assert {:error, :blocked_host} = PublicAddress.resolve_public("localhost")
    assert {:error, :blocked_host} = PublicAddress.resolve_public("127.0.0.1")
    assert {:error, :blocked_host} = PublicAddress.resolve_public("[::1]")
    assert {:ok, {1, 1, 1, 1}} = PublicAddress.resolve_public("1.1.1.1")
  end
end
