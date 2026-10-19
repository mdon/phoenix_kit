defmodule PhoenixKit.API.MCP.OriginCanonicalTest do
  @moduledoc """
  The two public helpers of `PhoenixKit.API.MCP.Origin` that the discovery
  documents use: the canonical origin and the list of known hosts.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness
  import Plug.Test

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP.Origin

  defmodule Hook do
    @moduledoc false
    def hosts(_conn), do: %{hosts: ["A.test", "b.test:8443", "shop.test"]}
    def language_only(_conn), do: %{language: "de"}
    def junk(_conn), do: %{hosts: ["a.test", 1]}
    def raises(_conn), do: raise("hook failure")
  end

  setup do
    KeyTestSupport.start_cache_registry!()

    start_supervised!(
      Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
    )

    on_exit(fn -> Application.delete_env(:phoenix_kit, :api_request_context) end)
    :ok
  end

  describe "canonical_origin/0" do
    test "is scheme://host of the site_url setting" do
      put_setting("site_url", "https://shop.test")
      assert Origin.canonical_origin() == "https://shop.test"
    end

    test "lowercases the host, drops a trailing slash and a default port, keeps another port" do
      for {site_url, origin} <- [
            {"https://Shop.TEST/", "https://shop.test"},
            {"https://shop.test:443", "https://shop.test"},
            {"http://shop.test:80/", "http://shop.test"},
            {"https://shop.test:8443", "https://shop.test:8443"},
            {"http://localhost:4000", "http://localhost:4000"},
            {"http://[::1]:4000", "http://[::1]:4000"}
          ] do
        put_setting("site_url", site_url)
        assert Origin.canonical_origin() == origin, site_url
      end
    end

    test "a path, query or userinfo in the setting is not part of the origin" do
      put_setting("site_url", "https://user:pw@shop.test/some/path?x=1")
      assert Origin.canonical_origin() == "https://shop.test"
    end

    test "without a usable site_url it is the endpoint's URL, a real origin" do
      for site_url <- ["", "ftp://shop.test", "not a url", "https://"] do
        put_setting("site_url", site_url)
        assert Origin.canonical_origin() =~ ~r{\Ahttps?://[a-z0-9.\[\]:-]+\z}, site_url
      end
    end

    test "reads the settings cache, not the database" do
      put_setting("site_url", "https://shop.test")
      _warm = Origin.canonical_origin()

      {origin, queries} = count_queries(&Origin.canonical_origin/0)

      assert origin == "https://shop.test"
      assert queries == 0
    end
  end

  describe "known_hosts/1" do
    defp request(host \\ "shop.test"), do: %{conn(:get, "/") | host: host}

    test "is the canonical host alone on a default install, whatever the request's Host" do
      put_setting("site_url", "https://shop.test")

      assert Origin.known_hosts(request("evil.example")) == ["shop.test"]
    end

    test "adds the hosts the hook returns explicitly, canonical first, lowercase, without ports" do
      put_setting("site_url", "https://shop.test")
      Application.put_env(:phoenix_kit, :api_request_context, {Hook, :hosts})

      assert Origin.known_hosts(request()) == ["shop.test", "a.test", "b.test"]
    end

    test "a hook with no :hosts, a bad list or a crash adds nothing" do
      put_setting("site_url", "https://shop.test")

      for fun <- [:language_only, :junk, :raises] do
        Application.put_env(:phoenix_kit, :api_request_context, {Hook, fun})

        ExUnit.CaptureLog.capture_log(fn ->
          assert Origin.known_hosts(request("a.test")) == ["shop.test"], "#{fun}"
        end)
      end
    end
  end

  defp count_queries(fun) do
    counter = :counters.new(1, [])
    test_pid = self()
    handler = "origin-canonical-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit, :test, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end
