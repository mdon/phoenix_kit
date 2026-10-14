defmodule PhoenixKit.API.MCP.OriginTest do
  @moduledoc """
  The Origin check of the MCP transport. `allowed?/3` is pure; `check/1` reads
  the install's host and the configured origins from the settings.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness
  import ExUnit.CaptureLog
  import Plug.Conn

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP.Origin

  defmodule Hook do
    @moduledoc false
    import Plug.Conn, only: [get_req_header: 2]

    def two_domains(_conn), do: %{hosts: ["a.test", "b.test"]}
    # A host hook that sets language and currency only, no :hosts.
    def language_only(_conn), do: %{language: "de", currency: "EUR"}
    def empty_hosts(_conn), do: %{hosts: []}
    def junk_hosts(_conn), do: %{hosts: ["a.test", 1]}
    def junk_return(_conn), do: :not_a_map
    def raises(_conn), do: raise("hook failure")
    def throws(_conn), do: throw(:hook_failure)

    # A scheme in a hook host is a misconfiguration: "//https://a.test" would read as the host "https".
    def scheme_host(_conn), do: %{hosts: ["https://a.test"]}

    # Failures that carry text taken from the request, for the log hygiene tests.
    def raises_request_text(conn), do: raise("failure for #{probe(conn)}")
    def throws_request_text(conn), do: throw({:probe, probe(conn)})
    def exits_request_text(conn), do: exit(probe(conn))

    defp probe(conn), do: conn |> get_req_header("x-probe") |> List.first()
  end

  setup do
    KeyTestSupport.start_cache_registry!()
    put_setting("site_url", "https://shop.test")
    on_exit(fn -> Application.delete_env(:phoenix_kit, :api_request_context) end)
    :ok
  end

  defp count_queries(fun) do
    counter = :counters.new(1, [])
    test_pid = self()
    handler = "origin-test-queries-#{System.unique_integer([:positive])}"

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

  defp conn_with(origin, opts \\ []) do
    conn = api_conn(:post, "/", opts)
    if origin, do: put_req_header(conn, "origin", origin), else: conn
  end

  describe "allowed?/3: hosts" do
    @hosts ["shop.test", "Other.TEST"]

    test "a listed host passes, with any scheme or port, in any case" do
      assert Origin.allowed?("https://shop.test", @hosts, [])
      assert Origin.allowed?("http://shop.test:8080", @hosts, [])
      assert Origin.allowed?("HTTPS://SHOP.TEST", @hosts, [])
      assert Origin.allowed?("https://other.test", @hosts, [])
    end

    test "lookalike hosts do not pass" do
      for origin <- [
            "https://shop.test.evil.com",
            "https://evilshop.test",
            "https://sub.shop.test",
            "https://shop.test.",
            "http://shop.tes",
            "https://evil.test"
          ] do
        refute Origin.allowed?(origin, @hosts, []), origin
      end
    end

    test "anything that is not a plain browser origin does not pass" do
      for origin <- [
            "null",
            "",
            "  ",
            "https://",
            "ftp://shop.test",
            "https://shop.test/",
            "https://shop.test/path",
            "https://shop.test?x=1",
            "https://shop.test#frag",
            "https://shop.test@evil.com",
            "https://user:pw@shop.test",
            "shop.test",
            "//shop.test",
            "https:shop.test"
          ] do
        refute Origin.allowed?(origin, @hosts, []), inspect(origin)
      end
    end

    test "an origin that is not valid UTF-8 does not pass and does not raise" do
      for origin <- [<<0xFF>>, "https://shop.test" <> <<0xFF>>, <<0xC3, 0x28>> <> ".test"] do
        refute Origin.allowed?(origin, @hosts, ["https://client.example"]), inspect(origin)
      end
    end

    test "an origin with surrounding whitespace does not pass" do
      refute Origin.allowed?(" https://shop.test", @hosts, [])
      refute Origin.allowed?("https://shop.test\t", @hosts, [])
      refute Origin.allowed?("https://shop.test ", @hosts, [])
    end

    test "a host entry may carry a port: only the hostname counts" do
      assert Origin.allowed?("http://localhost:3000", ["localhost:4000"], [])
    end
  end

  describe "allowed?/3: configured origins" do
    @configured [
      "https://client.example",
      "https://app.example:8443/",
      "partner.example",
      "Local.test:4000"
    ]

    # The last two entries are bare hosts: the Settings page never stores them
    # and this check never honours them.

    test "a full origin compares scheme, host and port" do
      assert Origin.allowed?("https://client.example", [], @configured)
      assert Origin.allowed?("https://client.example:443", [], @configured)
      assert Origin.allowed?("HTTPS://CLIENT.EXAMPLE", [], @configured)
      assert Origin.allowed?("https://app.example:8443", [], @configured)

      refute Origin.allowed?("http://client.example", [], @configured)
      refute Origin.allowed?("https://client.example:8443", [], @configured)
      refute Origin.allowed?("https://client.example.evil.com", [], @configured)
      refute Origin.allowed?("https://app.example", [], @configured)
      refute Origin.allowed?("https://app.example:9", [], @configured)
    end

    test "a bare entry (no scheme) never matches: only full origins are honoured" do
      refute Origin.allowed?("https://partner.example", [], @configured)
      refute Origin.allowed?("http://partner.example:81", [], @configured)
      refute Origin.allowed?("http://local.test:5000", [], @configured)
      refute Origin.allowed?("http://local.test:4000", [], @configured)
    end

    test "a configured entry may be padded and upper case" do
      assert Origin.allowed?("https://client.example", [], ["  HTTPS://Client.Example/ "])
    end

    test "an empty or blank entry never matches" do
      refute Origin.allowed?("https://anything.test", [], ["", "  ", "/", "://"])
    end
  end

  describe "check/1" do
    test "a request without Origin passes: that is every non-browser client" do
      conn = Origin.check(conn_with(nil))
      refute conn.halted
    end

    test "the install's own host passes" do
      refute Origin.check(conn_with("https://shop.test")).halted
      refute Origin.check(conn_with("http://shop.test:4000")).halted
    end

    test "a rebinding page is refused: Host and Origin are both the attacker's" do
      conn = %{conn_with("http://evil.test") | host: "evil.test"}

      conn = Origin.check(conn)

      assert conn.halted
      assert conn.status == 403
      assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")

      assert %{"code" => "origin_not_allowed", "context" => %{"origin" => "http://evil.test"}} =
               JSON.decode!(conn.resp_body)
    end

    test "a foreign Origin on a request for the install's own host is refused" do
      conn = %{conn_with("https://evil.test") | host: "shop.test"}
      assert Origin.check(conn).status == 403
    end

    test "an Origin that is not valid UTF-8 is refused with 403, never a crash" do
      conn = Origin.check(conn_with(<<0xFF>>))

      assert conn.halted
      assert conn.status == 403

      assert %{"code" => "origin_not_allowed", "context" => %{"origin" => origin}} =
               JSON.decode!(conn.resp_body)

      assert String.valid?(origin)
    end

    test "two Origin headers that are not valid UTF-8 are refused with 403" do
      conn = conn_with(nil)

      conn = %{
        conn
        | req_headers: [{"origin", <<0xFF>>}, {"origin", <<0xFE>>} | conn.req_headers]
      }

      assert Origin.check(conn).status == 403
    end

    test "Origin: null is refused" do
      assert Origin.check(conn_with("null")).status == 403
    end

    test "two Origin headers are refused" do
      conn = conn_with(nil)

      conn = %{
        conn
        | req_headers: [
            {"origin", "https://shop.test"},
            {"origin", "https://shop.test"} | conn.req_headers
          ]
      }

      assert Origin.check(conn).status == 403
    end

    test "an Origin from api_mcp_allowed_origins passes, one written otherwise does not" do
      put_setting("api_mcp_allowed_origins", "https://client.example\nhttps://app.example:8443")

      refute Origin.check(conn_with("https://client.example")).halted
      refute Origin.check(conn_with("https://app.example:8443")).halted
      assert Origin.check(conn_with("http://client.example")).status == 403
      assert Origin.check(conn_with("https://app.example")).status == 403
    end

    test "a host hook adds its domains and keeps the install's own host" do
      Application.put_env(:phoenix_kit, :api_request_context, {Hook, :two_domains})

      refute Origin.check(conn_with("https://a.test")).halted
      refute Origin.check(conn_with("https://b.test")).halted
      refute Origin.check(conn_with("https://shop.test")).halted
      assert Origin.check(conn_with("https://c.test")).status == 403
    end

    test "a hook host written with a scheme matches nothing" do
      Application.put_env(:phoenix_kit, :api_request_context, {Hook, :scheme_host})

      assert Origin.check(conn_with("https://a.test")).status == 403
      assert Origin.check(conn_with("http://https")).status == 403
      refute Origin.check(conn_with("https://shop.test")).halted
    end

    test "without the hook those domains are foreign" do
      assert Origin.check(conn_with("https://b.test")).status == 403
    end

    # The default host list of RequestContext is the Host
    # header, which the attacker controls. A hook that does not explicitly
    # return :hosts, or fails, must leave the list at the install's own host.
    for hook <- [:language_only, :empty_hosts, :junk_hosts, :junk_return, :raises, :throws] do
      test "hook #{hook} does not turn the Host header into an allowed host" do
        Application.put_env(:phoenix_kit, :api_request_context, {Hook, unquote(hook)})

        conn = %{conn_with("http://evil.test") | host: "evil.test"}

        {conn, _log} = ExUnit.CaptureLog.with_log(fn -> Origin.check(conn) end)

        assert conn.halted
        assert conn.status == 403
        assert %{"code" => "origin_not_allowed"} = JSON.decode!(conn.resp_body)
      end

      test "hook #{hook} still lets the install's own host through" do
        Application.put_env(:phoenix_kit, :api_request_context, {Hook, unquote(hook)})

        {conn, _log} =
          ExUnit.CaptureLog.with_log(fn -> Origin.check(conn_with("https://shop.test")) end)

        refute conn.halted
      end
    end

    test "a hook that returns some non-string hosts is ignored as a whole" do
      Application.put_env(:phoenix_kit, :api_request_context, {Hook, :junk_hosts})

      assert Origin.check(conn_with("https://a.test")).status == 403
    end

    @sentinel "probe-7f3a91c2"

    defp check_with_probe(hook) do
      Application.put_env(:phoenix_kit, :api_request_context, {Hook, hook})
      conn = put_req_header(conn_with("https://shop.test"), "x-probe", @sentinel)

      {conn, log} = with_log(fn -> Origin.check(conn) end)
      refute conn.halted
      log
    end

    test "a hook that raises logs its class, never its message" do
      log = check_with_probe(:raises_request_text)

      assert log =~ "RuntimeError"
      refute log =~ @sentinel
    end

    test "a hook that throws a request value logs only the shape" do
      log = check_with_probe(:throws_request_text)

      assert log =~ "throw: a tuple of size 2;"
      refute log =~ @sentinel
    end

    test "a hook that exits with a request value logs only the shape" do
      log = check_with_probe(:exits_request_text)

      assert log =~ "exit: a binary of #{byte_size(@sentinel)} bytes"
      refute log =~ @sentinel
    end

    test "a hook that is not {module, function} contributes nothing" do
      Application.put_env(:phoenix_kit, :api_request_context, :nonsense)

      conn = %{conn_with("http://evil.test") | host: "evil.test"}
      {conn, _log} = ExUnit.CaptureLog.with_log(fn -> Origin.check(conn) end)

      assert conn.status == 403
    end

    test "as the pre-authentication hook, an Origin that is not valid UTF-8 is a 403, never a 500" do
      switch(:public, true)

      conn =
        Auth.call(
          conn_with(<<0xFF>>),
          Auth.init(audience: :public, before_auth: {Origin, :check})
        )

      assert conn.halted
      assert conn.status == 403
      assert %{"code" => "origin_not_allowed"} = JSON.decode!(conn.resp_body)
    end

    # The check runs before any limiter: a flood of foreign Origins must not
    # become a flood of database queries.
    test "a refused Origin costs no database query once the settings are cached" do
      start_supervised!(
        Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
      )

      put_setting("api_mcp_allowed_origins", "https://client.example")
      conn = conn_with("https://evil.test")
      assert Origin.check(conn).status == 403

      {statuses, queries} =
        count_queries(fn -> for _ <- 1..5, do: Origin.check(conn).status end)

      assert statuses == [403, 403, 403, 403, 403]
      assert queries == 0
    end

    test "a very long Origin is clipped in the answer" do
      conn = Origin.check(conn_with("https://" <> String.duplicate("a", 5_000) <> ".test"))

      assert conn.status == 403
      assert String.length(JSON.decode!(conn.resp_body)["context"]["origin"]) <= 200
    end
  end
end
