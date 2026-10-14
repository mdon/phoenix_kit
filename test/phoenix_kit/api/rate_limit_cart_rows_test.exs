defmodule PhoenixKit.API.RateLimitCartRowsTest do
  @moduledoc """
  The hourly limits on new carts: per client network and global.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.Users.RateLimiter.Backend

  @hour 3_600_000
  @global_cart_rows_key "api:cart_rows:global"

  setup do
    start_cache_registry!()
    wait_for_window_room(@hour)

    # The one counter every client shares; start each test from zero and leave
    # it that way.
    Backend.set(@global_cart_rows_key, @hour, 0)
    on_exit(fn -> Backend.set(@global_cart_rows_key, @hour, 0) end)
    :ok
  end

  describe "check_cart_rows/1" do
    test "limits new carts per network and hour" do
      set_limit("api_public_cart_rows_per_ip_hour", 2)
      ip = unique_ip()

      assert :ok = RateLimit.check_cart_rows(ip)
      assert :ok = RateLimit.check_cart_rows(ip)
      assert {:error, retry_after} = RateLimit.check_cart_rows(ip)
      assert_hour_window("api:cart_rows:ip:" <> ip, retry_after)

      assert :ok = RateLimit.check_cart_rows(unique_ip())
    end

    test "has a ceiling across all networks" do
      set_limit("api_public_cart_rows_per_ip_hour", 100)
      set_limit("api_public_cart_rows_global_hour", 3)

      for _ <- 1..3, do: assert(:ok = RateLimit.check_cart_rows(unique_ip()))
      assert {:error, retry_after} = RateLimit.check_cart_rows(unique_ip())
      assert_hour_window(@global_cart_rows_key, retry_after)
    end
  end

  # Pins the window to the hour, not just to "somewhere in 1..3600": the counter
  # must sit in an hour window (Backend.expires_at/2 finds an entry only under
  # the scale it was written with, and answers 0 otherwise), and the refusal must
  # name the end of that window. A minute-based bucket fails the first check
  # and a minute-based retry-after the second.
  defp assert_hour_window(key, retry_after) do
    expires_at = Backend.expires_at(key, @hour)
    assert expires_at > 0, "no counter in an hour window for #{key}"
    assert rem(expires_at, @hour) == 0

    seconds_left = div(expires_at - Hammer.ETS.now(), 1000)
    assert retry_after in seconds_left..(seconds_left + 2)
  end
end
