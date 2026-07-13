defmodule PhoenixKit.Utils.UserAgentTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.UserAgent

  describe "browser/1" do
    test "recognizes common browsers" do
      assert UserAgent.browser("Mozilla/5.0 ... Edg/120.0.0.0") == "Edge"
      assert UserAgent.browser("Mozilla/5.0 ... OPR/106.0.0.0") == "Opera"

      assert UserAgent.browser("Mozilla/5.0 (X11; Linux) Gecko/20100101 Firefox/120.0") ==
               "Firefox"

      assert UserAgent.browser("Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/120.0") ==
               "Chrome"

      assert UserAgent.browser("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Safari/605.1.15") ==
               "Safari"
    end

    test "Edge is detected before Chrome (Edge UA also contains 'Chrome')" do
      ua = "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/120.0 Safari/537.36 Edg/120.0"
      assert UserAgent.browser(ua) == "Edge"
    end

    test "returns nil for nil or unrecognized input" do
      assert UserAgent.browser(nil) == nil
      assert UserAgent.browser("some-unknown-client/1.0") == nil
    end
  end

  describe "os/1" do
    test "recognizes common operating systems" do
      assert UserAgent.os("Mozilla/5.0 (Windows NT 10.0; Win64; x64)") == "Windows"
      assert UserAgent.os("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)") == "iOS"
      assert UserAgent.os("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)") == "iOS"
      assert UserAgent.os("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)") == "macOS"
      assert UserAgent.os("Mozilla/5.0 (Linux; Android 14)") == "Android"
      assert UserAgent.os("Mozilla/5.0 (X11; Linux x86_64)") == "Linux"
    end

    test "iOS is detected before Android/Linux fallback confusion doesn't occur" do
      assert UserAgent.os("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)") == "iOS"
    end

    test "returns nil for nil or unrecognized input" do
      assert UserAgent.os(nil) == nil
      assert UserAgent.os("some-unknown-client/1.0") == nil
    end
  end
end
