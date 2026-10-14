defmodule PhoenixKit.API.RateLimitAdminTest do
  @moduledoc """
  The per-key admin bucket: limits, cost weighting and the headers; and that the
  pre-auth bucket never locks out a valid key (Review Focus #4).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Token
  alias PhoenixKit.API.RateLimit

  setup do
    wait_for_window_room()
    register_fake_module!()
    start_key_cache!()
    :ok
  end

  describe "check_admin/2" do
    test "allows up to the limit and then refuses with Retry-After" do
      set_limit("api_admin_rate_per_min", 3)
      key_uuid = UUIDv7.generate()

      for expected_remaining <- [2, 1, 0] do
        assert {:ok, headers} = RateLimit.check_admin(key_uuid, 1)
        assert header_value(headers, "ratelimit-limit") == 3
        assert header_value(headers, "ratelimit-remaining") == expected_remaining
        assert header_value(headers, "ratelimit-reset") in 1..60
        refute List.keymember?(headers, "retry-after", 0)
      end

      assert {:error, retry_after, headers} = RateLimit.check_admin(key_uuid, 1)
      assert retry_after in 1..60
      assert header_value(headers, "retry-after") == retry_after
      assert header_value(headers, "ratelimit-limit") == 3
      assert header_value(headers, "ratelimit-remaining") == 0
      assert header_value(headers, "ratelimit-reset") == retry_after
    end

    test "header names are lower case, as Plug requires" do
      {:ok, headers} = RateLimit.check_admin(UUIDv7.generate(), 1)

      for {name, value} <- headers do
        assert name == String.downcase(name)
        assert is_binary(value)
      end
    end

    test "weights a call by its cost" do
      set_limit("api_admin_rate_per_min", 10)
      key_uuid = UUIDv7.generate()

      assert {:ok, headers} = RateLimit.check_admin(key_uuid, 4)
      assert header_value(headers, "ratelimit-remaining") == 6
      assert {:ok, headers} = RateLimit.check_admin(key_uuid, 4)
      assert header_value(headers, "ratelimit-remaining") == 2
      assert {:error, _, _} = RateLimit.check_admin(key_uuid, 4)
      # A cheaper call after a refusal is still refused: the window is spent.
      assert {:error, _, _} = RateLimit.check_admin(key_uuid, 1)
    end

    test "a single call dearer than the whole limit is refused" do
      set_limit("api_admin_rate_per_min", 5)
      assert {:error, _, headers} = RateLimit.check_admin(UUIDv7.generate(), 6)
      assert header_value(headers, "ratelimit-remaining") == 0
    end

    test "each key has its own bucket" do
      set_limit("api_admin_rate_per_min", 1)
      a = UUIDv7.generate()
      b = UUIDv7.generate()

      assert {:ok, _} = RateLimit.check_admin(a, 1)
      assert {:error, _, _} = RateLimit.check_admin(a, 1)
      assert {:ok, _} = RateLimit.check_admin(b, 1)
    end

    test "refuses a cost that is not a positive integer" do
      for bad <- [0, -1, 1.5, nil] do
        assert_raise FunctionClauseError, fn -> RateLimit.check_admin(UUIDv7.generate(), bad) end
      end
    end
  end

  describe "Review Focus #4: failures throttle failing authentication only" do
    # What the Auth plug does with these functions (Task 12): peek the pre-auth
    # bucket, always verify, charge a failure only when the address was not yet
    # throttled; a failed authentication is answered 401, or 429 once the address
    # was throttled (spec 16.5); a valid key is never refused for its address's
    # failures.
    defp authenticate(token, ip) do
      throttle = RateLimit.check_preauth(ip)

      case Keys.verify(token, ip) do
        {:ok, actor} ->
          {:ok, actor}

        {:error, _reason} ->
          case throttle do
            :ok ->
              :ok = RateLimit.record_auth_failure(ip)
              {:error, :unauthorized}

            {:error, retry_after} ->
              {:error, {:rate_limited, retry_after}}
          end
      end
    end

    test "guessing from one address is throttled but a valid key from the same address passes" do
      set_limit("api_admin_preauth_fail_per_min", 3)
      set_limit("api_admin_rate_per_min", 10)
      {user, _role, scope} = api_holder(["media"])
      {key, token} = create_key!(user, scope)
      ip = unique_ip()
      {_, guess, _} = Token.generate()

      assert {:error, :unauthorized} = authenticate(guess, ip)
      assert {:error, :unauthorized} = authenticate(guess, ip)
      assert {:error, :unauthorized} = authenticate(guess, ip)

      # The address is now exhausted: more guessing is refused outright.
      assert {:error, {:rate_limited, retry_after}} = authenticate(guess, ip)
      assert retry_after in 1..60

      # The accounting system behind the same egress address still works.
      assert {:ok, actor} = authenticate(token, ip)
      assert actor.key_uuid == key.uuid
      assert {:ok, headers} = RateLimit.check_admin(actor.key_uuid, 1)
      # The failures of the address did not touch the key's own bucket.
      assert header_value(headers, "ratelimit-limit") == 10
      assert header_value(headers, "ratelimit-remaining") == 9

      # Successes are not failures: they never feed the pre-auth bucket.
      for _ <- 1..10, do: assert({:ok, _} = authenticate(token, ip))
      assert {:error, {:rate_limited, _}} = authenticate(guess, ip)
    end

    test "the pre-auth bucket is independent of the per-key bucket" do
      set_limit("api_admin_preauth_fail_per_min", 1)
      set_limit("api_admin_rate_per_min", 5)
      ip = unique_ip()

      RateLimit.record_auth_failure(ip)
      assert {:error, _} = RateLimit.check_preauth(ip)

      key_uuid = UUIDv7.generate()
      assert {:ok, _} = RateLimit.check_admin(key_uuid, 1)
    end
  end
end
