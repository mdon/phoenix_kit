defmodule PhoenixKit.API.Keys.CIDRTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Keys.CIDR

  describe "normalize/1" do
    test "keeps a CIDR and writes a bare address as a single-host block" do
      assert CIDR.normalize("203.0.113.0/24") == {:ok, "203.0.113.0/24"}
      assert CIDR.normalize("203.0.113.7") == {:ok, "203.0.113.7/32"}
      assert CIDR.normalize(" 203.0.113.7/32 ") == {:ok, "203.0.113.7/32"}
      assert CIDR.normalize("2001:DB8::/32") == {:ok, "2001:db8::/32"}
      assert CIDR.normalize("::1") == {:ok, "::1/128"}
      assert CIDR.normalize("0.0.0.0/0") == {:ok, "0.0.0.0/0"}
    end

    test "checks the prefix length against the address family" do
      assert CIDR.normalize("10.0.0.0/32") == {:ok, "10.0.0.0/32"}
      assert CIDR.normalize("10.0.0.0/33") == :error
      assert CIDR.normalize("2001:db8::/128") == {:ok, "2001:db8::/128"}
      assert CIDR.normalize("2001:db8::/129") == :error
      assert CIDR.normalize("10.0.0.0/-1") == :error
    end

    test "refuses text that is not an address or CIDR" do
      for bad <- [
            "",
            "/24",
            "10.0.0.0/",
            "10.0.0.0/24/1",
            "10.0.0.0/x",
            "10.0.0.0/2x",
            "10.0.0.0/+8",
            "10.0.0.0/-0",
            "2001:db8::/+64",
            "10.0.0",
            "10.1",
            "256.0.0.1",
            "example.com",
            "10.0.0.1 /24",
            nil,
            7
          ] do
        assert CIDR.normalize(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "normalize_all/1" do
    test "normalises and de-duplicates" do
      assert CIDR.normalize_all(["203.0.113.7", "203.0.113.7/32", "10.0.0.0/8"]) ==
               {:ok, ["203.0.113.7/32", "10.0.0.0/8"]}
    end

    test "names every invalid entry" do
      assert CIDR.normalize_all(["10.0.0.0/8", "nope", "1.2.3.4/99"]) ==
               {:error, ["nope", "1.2.3.4/99"]}
    end

    test "an empty list is valid" do
      assert CIDR.normalize_all([]) == {:ok, []}
    end
  end

  describe "allowed?/2" do
    test "matches addresses inside an IPv4 block" do
      entries = ["203.0.113.0/24"]
      assert CIDR.allowed?(entries, "203.0.113.7")
      assert CIDR.allowed?(entries, "203.0.113.255")
      refute CIDR.allowed?(entries, "203.0.114.1")
      refute CIDR.allowed?(entries, "10.0.0.1")
    end

    test "a /32 matches only that host and a /0 matches the whole family" do
      assert CIDR.allowed?(["203.0.113.7/32"], "203.0.113.7")
      refute CIDR.allowed?(["203.0.113.7/32"], "203.0.113.8")
      assert CIDR.allowed?(["0.0.0.0/0"], "198.51.100.9")
      refute CIDR.allowed?(["0.0.0.0/0"], "2001:db8::1")
    end

    test "matches addresses inside an IPv6 block and never across families" do
      assert CIDR.allowed?(["2001:db8::/32"], "2001:db8:abcd::1")
      refute CIDR.allowed?(["2001:db8::/32"], "2001:db9::1")
      refute CIDR.allowed?(["2001:db8::/32"], "32.1.13.184")
      refute CIDR.allowed?(["10.0.0.0/8"], "::a00:1")
    end

    test "an IPv4-mapped IPv6 client counts as IPv4" do
      assert CIDR.allowed?(["203.0.113.0/24"], "::ffff:203.0.113.7")
      refute CIDR.allowed?(["203.0.113.0/24"], "::ffff:198.51.100.7")
    end

    test "any entry may match and unparsable entries match nothing" do
      assert CIDR.allowed?(["10.0.0.0/8", "garbage", "203.0.113.7"], "203.0.113.7")
      refute CIDR.allowed?(["garbage"], "203.0.113.7")
    end

    test "an empty list, a missing client address or a bad one never match" do
      refute CIDR.allowed?([], "203.0.113.7")
      refute CIDR.allowed?(["0.0.0.0/0"], nil)
      refute CIDR.allowed?(["0.0.0.0/0"], "unknown")
    end

    test "host bits in the entry are ignored" do
      assert CIDR.allowed?(["203.0.113.77/24"], "203.0.113.1")
    end
  end
end
