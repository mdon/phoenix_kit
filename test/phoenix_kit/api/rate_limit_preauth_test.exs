defmodule PhoenixKit.API.RateLimitPreauthTest do
  @moduledoc """
  The admin pre-auth bucket: peeked before authentication, charged only by
  failures, so guessing is throttled without locking out a valid key. Counters live in one ETS table shared by the whole run, so every
  test uses addresses of its own.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.RateLimit

  setup do
    start_cache_registry!()
    wait_for_window_room()
    :ok
  end

  describe "check_preauth/1 and record_auth_failure/1" do
    test "an address that has not failed passes, and peeking charges nothing" do
      ip = unique_ip()

      for _ <- 1..50, do: assert(:ok = RateLimit.check_preauth(ip))

      set_limit("api_admin_preauth_fail_per_min", 3)
      for _ <- 1..3, do: RateLimit.record_auth_failure(ip)
      assert {:error, _} = RateLimit.check_preauth(ip)
    end

    test "is exhausted by failures only, after exactly the configured number" do
      ip = unique_ip()
      set_limit("api_admin_preauth_fail_per_min", 3)

      for _ <- 1..2 do
        assert :ok = RateLimit.record_auth_failure(ip)
        assert :ok = RateLimit.check_preauth(ip)
      end

      assert :ok = RateLimit.record_auth_failure(ip)
      assert {:error, retry_after} = RateLimit.check_preauth(ip)
      assert retry_after in 1..60
    end

    test "one address does not use up another" do
      set_limit("api_admin_preauth_fail_per_min", 2)
      noisy = unique_ip()
      quiet = unique_ip()

      for _ <- 1..5, do: RateLimit.record_auth_failure(noisy)

      assert {:error, _} = RateLimit.check_preauth(noisy)
      assert :ok = RateLimit.check_preauth(quiet)
    end

    test "IPv6 addresses of one /64 share a bucket" do
      set_limit("api_admin_preauth_fail_per_min", 2)
      # unique_integer/1 is not small: spread it over two 16-bit groups so that
      # each group stays 1 to 4 hex digits however high the counter has climbed.
      n = System.unique_integer([:positive])
      hi = Integer.to_string(rem(div(n, 65_536), 65_536), 16)
      lo = Integer.to_string(rem(n, 65_536), 16)
      a = "2001:db8:#{hi}:#{lo}::1"
      b = "2001:db8:#{hi}:#{lo}::ffff"
      elsewhere = "2001:db9:#{hi}:#{lo}::1"

      # An invalid address is not shortened to its /64, which would quietly change
      # what this test proves.
      for address <- [a, b, elsewhere],
          do: assert({:ok, _} = :inet.parse_strict_address(String.to_charlist(address)))

      for _ <- 1..2, do: RateLimit.record_auth_failure(a)

      assert {:error, _} = RateLimit.check_preauth(b)
      assert :ok = RateLimit.check_preauth(elsewhere)
    end
  end
end
