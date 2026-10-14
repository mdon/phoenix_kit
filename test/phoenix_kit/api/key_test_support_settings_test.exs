defmodule PhoenixKit.API.KeyTestSupportSettingsTest do
  @moduledoc """
  `PhoenixKit.API.KeyTestSupport.write_setting/1`: a settings write of a test
  that runs no `:settings` cache passes with the one warning that is expected
  there and fails the test on any other log line.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  require Logger

  setup do
    # The registry runs, the `:settings` cache does not: the write logs
    # "Cache settings could not be invalidated: {:noproc, ...}".
    start_key_cache!()
  end

  test "put_setting writes the value although the write logs the expected warning" do
    assert :ok = put_setting("api_admin_rate_per_min", 7)
    assert PhoenixKit.Settings.get_setting("api_admin_rate_per_min") == "7"
  end

  test "write_setting passes when the expected warning is the only line" do
    assert :ok = write_setting(fn -> PhoenixKit.Settings.update_setting("k_a", "v") end)
  end

  test "any other line fails the test and is named in the failure" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        write_setting(fn ->
          Logger.warning("a different warning")
          PhoenixKit.Settings.update_setting("k_b", "v")
        end)
      end

    assert error.message =~ "a different warning"
    refute error.message =~ "could not be invalidated"
  end

  test "a write that does not return {:ok, _} fails the test" do
    assert_raise MatchError, fn -> write_setting(fn -> {:error, :nope} end) end
  end
end
