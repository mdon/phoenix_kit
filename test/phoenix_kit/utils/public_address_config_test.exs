defmodule PhoenixKit.Utils.PublicAddressConfigTest do
  @moduledoc """
  `:blocked_ip_ranges` — ranges only the host's network knows about, such as
  a network-specific NAT64 prefix that maps every IPv4 address (internal
  ones included) into global-looking IPv6.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Utils.PublicAddress

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit, :blocked_ip_ranges) end)
  end

  test "a configured NAT64 prefix is refused, and so is the IPv4 it hides" do
    # 2a00:abcd:1234:5678::a00:1 is 10.0.0.1 through that gateway.
    assert PublicAddress.public?("2a00:abcd:1234:5678::a00:1")

    Application.put_env(:phoenix_kit, :blocked_ip_ranges, [
      "2a00:abcd:1234:5678::/96",
      "203.0.114.0/24"
    ])

    refute PublicAddress.public?("2a00:abcd:1234:5678::a00:1")
    assert PublicAddress.public?("2a00:abcd:1234:5679::1")
    refute PublicAddress.public?("203.0.114.9")
    assert PublicAddress.public?("8.8.8.8")
  end

  test "unparsable entries are ignored" do
    Application.put_env(:phoenix_kit, :blocked_ip_ranges, ["nope", "1.2.3.4/99", "1.2.3.4", :x])
    assert PublicAddress.public?("1.2.3.4")
  end
end
