defmodule PhoenixKit.API.RESTTest do
  @moduledoc """
  `PhoenixKit.API.REST` at plug level: the conn carries the path as the
  router's `forward` leaves it (the tool name alone, or nothing), the way
  `Phoenix.Router` hands it over. The same plug through the real endpoint and
  router is in `PhoenixKitWeb.APIRoutingTest`.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness
  import Plug.Conn

  alias PhoenixKit.API.REST
  alias PhoenixKit.ModuleRegistry

  defmodule BrokenTextModule do
    @moduledoc false
    alias PhoenixKit.API.Tool

    def enabled?, do: true

    def api_tools do
      [
        %Tool{
          name: "restutf.bad_description",
          audience: :admin,
          scope: "testkit.items:read",
          permission: "dashboard",
          title: "Bad description",
          description: <<0xFF, 0xFE>>,
          input_schema: %{"type" => "object"},
          handler: {__MODULE__, :run}
        },
        %Tool{
          name: "restutf.bad_title",
          audience: :public,
          title: <<0xFF>>,
          description: "",
          input_schema: %{"type" => "object"},
          handler: {__MODULE__, :run}
        }
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  @read "testkit.items:read"
  @write "testkit.items:write"

  setup do
    setup_api()
    {owner, _role} = user_with(["dashboard", "settings"])
    {_key, token} = issue_key(owner, [@read, @write])
    %{token: token}
  end

  defp admin(conn), do: REST.call(conn, REST.init(audience: :admin))
  defp public(conn), do: REST.call(conn, REST.init(audience: :public))

  defp problem(conn) do
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    json(conn)
  end

  describe "init/1" do
    test "keeps a known audience and refuses anything else" do
      assert [audience: :public] = REST.init(audience: :public)
      assert_raise ArgumentError, fn -> REST.init(audience: :nope) end
      assert_raise KeyError, fn -> REST.init([]) end
    end
  end

  describe "POST /<tool>" do
    test "runs the tool with the body as input", %{token: token} do
      conn =
        :post |> api_conn("/testkit.read_items", token: token, body: %{"limit" => 4}) |> admin()

      assert conn.status == 200
      assert json(conn)["limit"] == 4
      assert_received {:read_items, %{"limit" => 4}, _ctx}
    end

    test "the dot in the tool name is part of the path", %{token: token} do
      conn = :post |> api_conn("/system.get_identity", token: token, body: %{}) |> admin()

      assert conn.status == 200
      assert %{"key" => %{}, "owner" => %{}, "scopes" => _, "tools" => _} = json(conn)
    end

    test "no body at all is an empty input", %{token: token} do
      conn = :post |> api_conn("/testkit.read_items", token: token) |> admin()
      assert conn.status == 200
      assert_received {:read_items, %{}, _ctx}
    end

    test "a JSON array body is refused as the wrong shape", %{token: token} do
      # BodyGuard turns an array into %{"_json" => list}.
      conn =
        :post
        |> api_conn("/testkit.read_items", token: token, body: %{"_json" => [1, 2]})
        |> admin()

      assert conn.status == 422
      assert inspect(json(conn)["context"]["errors"]) =~ "_json"
    end

    test "an unknown tool is a 404 problem", %{token: token} do
      conn = :post |> api_conn("/testkit.nope", token: token, body: %{}) |> admin()
      assert conn.status == 404
      assert %{"code" => "not_found"} = problem(conn)
    end

    test "a path with more than one segment is a 404 problem", %{token: token} do
      for path <- ["/testkit.read_items/extra", "/a/b/c"] do
        conn = :post |> api_conn(path, token: token, body: %{}) |> admin()
        assert conn.status == 404, path
        assert %{"code" => "not_found"} = problem(conn)
      end
    end

    test "no key is a 401 problem" do
      conn = :post |> api_conn("/testkit.read_items", body: %{}) |> admin()
      assert conn.status == 401
      assert %{"code" => "unauthorized"} = problem(conn)
    end
  end

  describe "GET /" do
    test "lists the visible tools", %{token: token} do
      for path <- ["/", ""] do
        conn = :get |> api_conn(path, token: token) |> admin()

        assert conn.status == 200, path
        names = json(conn)["tools"] |> Enum.map(& &1["name"])
        assert "system.get_identity" in names
        assert "testkit.read_items" in names
      end
    end
  end

  describe "GET / with a tool whose text is not valid UTF-8" do
    setup do
      :ok = ModuleRegistry.register(BrokenTextModule)
      on_exit(fn -> ModuleRegistry.unregister(BrokenTextModule) end)
    end

    @tag capture_log: true
    test "still answers 200 and leaves the broken tool out", %{token: token} do
      conn = :get |> api_conn("/", token: token) |> admin()
      assert conn.status == 200
      names = json(conn)["tools"] |> Enum.map(& &1["name"])
      assert "testkit.read_items" in names
      refute "restutf.bad_description" in names

      conn = :get |> api_conn("/") |> public()
      assert conn.status == 200
      refute "restutf.bad_title" in (json(conn)["tools"] |> Enum.map(& &1["name"]))
    end
  end

  describe "other methods are 405 problems with an Allow header" do
    test "a tool path accepts POST only", %{token: token} do
      for method <- [:get, :put, :patch, :delete, :options] do
        conn = method |> api_conn("/testkit.read_items", token: token) |> admin()

        assert conn.status == 405, "#{method}"
        assert ["POST"] = get_resp_header(conn, "allow")
        assert %{"code" => "method_not_allowed"} = problem(conn)
      end
    end

    test "the root accepts GET only", %{token: token} do
      for method <- [:post, :put, :patch, :delete] do
        conn = method |> api_conn("/", token: token) |> admin()

        assert conn.status == 405, "#{method}"
        assert ["GET"] = get_resp_header(conn, "allow")
      end
    end

    test "authentication comes first: no key, no 405", %{} do
      assert 401 == (:get |> api_conn("/testkit.read_items") |> admin()).status
    end
  end

  describe "the API switch" do
    test "off: every path is a 404, whatever the method" do
      switch(:admin, false)

      for {method, path} <- [post: "/testkit.read_items", get: "/", delete: "/x", options: "/x"] do
        conn = method |> api_conn(path) |> admin()
        assert conn.status == 404, path
        assert %{"code" => "not_found"} = problem(conn)
      end
    end
  end

  describe "CORS" do
    test "the public audience answers any origin, without credentials" do
      conn = :post |> api_conn("/testkit.public_echo", body: %{"text" => "hi"}) |> public()

      assert conn.status == 200
      assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
      assert [] = get_resp_header(conn, "access-control-allow-credentials")
      assert json(conn)["echo"] == "hi"
    end

    test "errors carry the header too, so a browser can read them" do
      conn = :post |> api_conn("/testkit.nope", body: %{}) |> public()
      assert conn.status == 404
      assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
    end

    test "answers expose the rate-limit and request-id headers to a browser script" do
      expected =
        ~w(retry-after ratelimit-limit ratelimit-remaining ratelimit-reset x-request-id idempotent-replayed)

      for conn <- [
            :post |> api_conn("/testkit.public_echo", body: %{"text" => "hi"}) |> public(),
            :post |> api_conn("/testkit.nope", body: %{}) |> public()
          ] do
        assert [exposed] = get_resp_header(conn, "access-control-expose-headers")
        assert String.split(exposed, ", ") == expected
      end
    end

    test "the admin audience exposes no headers", %{token: token} do
      ok = :post |> api_conn("/testkit.read_items", token: token, body: %{}) |> admin()
      assert [] = get_resp_header(ok, "access-control-expose-headers")
    end

    test "the preflight is a 204 with the allowed methods and headers" do
      conn = :options |> api_conn("/testkit.public_echo") |> public()

      assert conn.status == 204
      assert conn.resp_body == ""
      assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
      assert ["GET, POST, OPTIONS"] = get_resp_header(conn, "access-control-allow-methods")

      assert ["content-type, idempotency-key"] =
               get_resp_header(conn, "access-control-allow-headers")
    end

    test "the admin audience sends no CORS headers, and refuses a preflight", %{token: token} do
      ok = :post |> api_conn("/testkit.read_items", token: token, body: %{}) |> admin()
      assert [] = get_resp_header(ok, "access-control-allow-origin")

      preflight = :options |> api_conn("/testkit.read_items", token: token) |> admin()
      assert preflight.status == 405
      assert [] = get_resp_header(preflight, "access-control-allow-origin")
    end
  end

  describe "the public audience" do
    test "lists its tools and runs them without a key" do
      assert ["testkit.public_echo"] ==
               :get
               |> api_conn("/")
               |> public()
               |> json()
               |> Map.fetch!("tools")
               |> Enum.map(& &1["name"])

      assert 404 == (:post |> api_conn("/testkit.read_items", body: %{}) |> public()).status
    end
  end
end
