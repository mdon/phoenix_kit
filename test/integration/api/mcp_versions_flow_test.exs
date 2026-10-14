defmodule PhoenixKit.API.MCPVersionsFlowTest do
  @moduledoc """
  The revision mechanism through the real endpoint: what `initialize` answers
  and which `MCP-Protocol-Version` header is refused follow
  `:mcp_protocol_versions`, and a revision added to the table through
  `:mcp_extra_revisions` is negotiable end to end with no other change.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.Test.ApiHarness

  import PhoenixKit.Test.McpHarness,
    only: [error: 1, message: 1, message: 2, message: 3, result: 1]

  alias PhoenixKit.Utils.Routes

  @read "testkit.items:read"
  @write "testkit.items:write"
  @admin "/mcp/admin"

  setup %{conn: conn} do
    for key <- [:mcp_protocol_versions, :mcp_extra_revisions] do
      previous = Application.fetch_env(:phoenix_kit, key)
      Application.delete_env(:phoenix_kit, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, key, value)
          :error -> Application.delete_env(:phoenix_kit, key)
        end
      end)
    end

    setup_api()
    put_setting("site_url", "https://shop.test")
    {owner, _role} = user_with(["dashboard", "settings"])
    {_key, token} = issue_key(owner, [@read, @write])
    %{conn: conn, token: token}
  end

  # One JSON-RPC message through the endpoint; `version: nil` sends no header.
  defp rpc(conn, token, body, version) do
    conn =
      conn
      |> with_client_ip(unique_ip())
      |> bearer(token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if version, do: put_req_header(conn, "mcp-protocol-version", version), else: conn

    post(conn, Routes.path(@admin), JSON.encode!(body))
  end

  defp initialize(version) do
    message("initialize", %{
      "protocolVersion" => version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "t", "version" => "1"}
    })
  end

  defp put_env(key, value), do: Application.put_env(:phoenix_kit, key, value)

  describe "by default" do
    test "2026-07-28 is refused on the header: 400, -32600, the three revisions listed", %{
      conn: conn,
      token: token
    } do
      conn = rpc(conn, token, message("ping", nil, 5), "2026-07-28")

      assert conn.status == 400
      assert %{"id" => 5} = JSON.decode!(conn.resp_body)
      assert error(conn)["code"] == -32_600
      assert error(conn)["message"] =~ "Supported: 2025-11-25, 2025-06-18, 2025-03-26."
    end

    test "initialize asked for 2026-07-28 answers the newest revision it speaks", %{
      conn: conn,
      token: token
    } do
      conn = rpc(conn, token, initialize("2026-07-28"), nil)

      assert result(conn)["protocolVersion"] == "2025-11-25"
    end
  end

  describe ":mcp_protocol_versions" do
    test "a revision taken out of the list is 400 on the header and negotiated down on initialize",
         %{conn: conn, token: token} do
      put_env(:mcp_protocol_versions, ["2025-06-18", "2025-03-26"])

      refused = rpc(conn, token, message("ping", nil, 9), "2025-11-25")
      assert refused.status == 400
      assert error(refused)["code"] == -32_600
      assert error(refused)["message"] =~ "Supported: 2025-06-18, 2025-03-26."
      refute error(refused)["message"] =~ "Supported: 2025-11-25"

      assert rpc(conn, token, message("ping"), "2025-06-18").status == 200

      negotiated = rpc(conn, token, initialize("2025-11-25"), nil)
      assert result(negotiated)["protocolVersion"] == "2025-06-18"
    end

    test "the order gives the answer to a revision nobody speaks", %{conn: conn, token: token} do
      put_env(:mcp_protocol_versions, ["2025-03-26", "2025-11-25"])

      answer = rpc(conn, token, initialize("1999-01-01"), nil)

      assert result(answer)["protocolVersion"] == "2025-03-26"
    end

    test "without the oldest revision a request without a header is 400, initialize still works",
         %{conn: conn, token: token} do
      put_env(:mcp_protocol_versions, ["2025-11-25", "2025-06-18"])

      missing = rpc(conn, token, message("ping", nil, 3), nil)
      assert missing.status == 400
      assert %{"id" => 3} = JSON.decode!(missing.resp_body)
      assert error(missing)["message"] =~ "header is required"
      assert error(missing)["message"] =~ "Supported: 2025-11-25, 2025-06-18."

      assert rpc(conn, token, initialize("2025-06-18"), nil).status == 200
    end

    test "with the oldest revision a request without a header still means it", %{
      conn: conn,
      token: token
    } do
      assert rpc(conn, token, message("ping"), nil).status == 200
    end
  end

  describe "a revision added to the table" do
    @extra "2027-01-01"

    setup do
      put_env(:mcp_extra_revisions, [
        {@extra, %{structured_content: true, tool_title: true}}
      ])
    end

    test "initialize answers it, with the server title its profile leaves out", %{
      conn: conn,
      token: token
    } do
      answer = rpc(conn, token, initialize(@extra), nil)

      assert result(answer)["protocolVersion"] == @extra
      refute Map.has_key?(result(answer)["serverInfo"], "title")
    end

    test "tools/list with its header works and follows its flags", %{conn: conn, token: token} do
      answer = rpc(conn, token, message("tools/list"), @extra)

      assert answer.status == 200
      tools = result(answer)["tools"]
      assert tools != []
      assert Enum.all?(tools, &Map.has_key?(&1, "title"))
      refute Enum.any?(tools, &Map.has_key?(&1, "outputSchema"))
    end

    test "tools/call with its header carries structuredContent", %{conn: conn, token: token} do
      wait_for_window_room()

      body = message("tools/call", %{"name" => "system_get_identity", "arguments" => %{}})
      answer = rpc(conn, token, body, @extra)

      assert answer.status == 200
      assert %{"isError" => false, "structuredContent" => %{}} = result(answer)
    end

    test "an unlisted newer revision is refused as before", %{conn: conn, token: token} do
      assert rpc(conn, token, message("ping"), "2026-07-28").status == 400
    end

    test "it can be left out of :mcp_protocol_versions while it stays in the table", %{
      conn: conn,
      token: token
    } do
      put_env(:mcp_protocol_versions, ["2025-11-25", "2025-06-18", "2025-03-26"])

      assert rpc(conn, token, message("ping"), @extra).status == 400
      assert result(rpc(conn, token, initialize(@extra), nil))["protocolVersion"] == "2025-11-25"
    end
  end
end
