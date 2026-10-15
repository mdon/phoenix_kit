defmodule PhoenixKit.API.MCP.RpcTest do
  @moduledoc """
  The JSON-RPC envelope of the MCP transport: how a decoded body is classified
  and how answers are built and sent. No database.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.API.MCP.Rpc

  defp req(extra), do: Map.merge(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, extra)

  describe "classify/1: what is a message" do
    test "a request keeps its id (integer or string) and its params as given" do
      assert {:request, 1, "ping", nil} = Rpc.classify(req(%{}))
      assert {:request, 0, "ping", nil} = Rpc.classify(req(%{"id" => 0}))

      assert {:request, "abc", "tools/list", %{"a" => 1}} =
               Rpc.classify(
                 req(%{"id" => "abc", "method" => "tools/list", "params" => %{"a" => 1}})
               )

      assert {:request, 9, "x", [1, 2]} =
               Rpc.classify(req(%{"id" => 9, "method" => "x", "params" => [1, 2]}))
    end

    test "a message without an id is a notification, whatever its method" do
      msg = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert {:notification, "notifications/initialized"} = Rpc.classify(msg)

      assert {:notification, "tools/call"} =
               Rpc.classify(%{
                 "jsonrpc" => "2.0",
                 "method" => "tools/call",
                 "params" => %{"name" => "x"}
               })
    end

    test "a result or an error with an id is a response from the client" do
      assert :response = Rpc.classify(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}})

      assert :response =
               Rpc.classify(%{"jsonrpc" => "2.0", "id" => "r", "error" => %{"code" => -1}})
    end
  end

  describe "classify/1: what is invalid" do
    test "no body, an empty body, a batch, a scalar" do
      assert {:invalid, nil, text} = Rpc.classify(%Plug.Conn.Unfetched{aspect: :body_params})
      assert text =~ "no JSON body"

      assert {:invalid, nil, text} = Rpc.classify(%{})
      assert text =~ "empty"

      assert {:invalid, nil, text} = Rpc.classify(%{"_json" => [req(%{}), req(%{"id" => 2})]})
      assert text =~ "Batch requests are not supported"

      assert {:invalid, nil, _} = Rpc.classify(%{"_json" => 7})
      assert {:invalid, nil, _} = Rpc.classify(%{"_json" => "text"})
      assert {:invalid, nil, _} = Rpc.classify(nil)
      assert {:invalid, nil, _} = Rpc.classify("text")
    end

    test "the jsonrpc member must be exactly \"2.0\"; a usable id is echoed" do
      for map <- [
            %{"id" => 1, "method" => "ping"},
            %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
            %{"jsonrpc" => 2.0, "id" => 1, "method" => "ping"}
          ] do
        assert {:invalid, 1, text} = Rpc.classify(map)
        assert text =~ ~s("jsonrpc" member)
      end
    end

    test "an id that is null, a float, a boolean or a map" do
      for id <- [nil, 1.5, true, %{"a" => 1}, [1]] do
        assert {:invalid, nil, text} = Rpc.classify(req(%{"id" => id}))
        assert text =~ "id must be a string or an integer"
      end
    end

    test "no method, or a method that is not a string" do
      assert {:invalid, 1, text} = Rpc.classify(%{"jsonrpc" => "2.0", "id" => 1})
      assert text =~ ~s("method" member)

      assert {:invalid, 1, _} = Rpc.classify(req(%{"method" => 5}))
      assert {:invalid, 1, _} = Rpc.classify(req(%{"method" => nil}))
      assert {:invalid, nil, _} = Rpc.classify(%{"jsonrpc" => "2.0", "method" => 5, "id" => nil})
    end

    test "never raises, whatever the shape" do
      for junk <- [1, 1.5, :atom, [], [1], {1, 2}, %{"a" => %{"b" => [nil]}}, %{"_json" => nil}] do
        assert match?({:invalid, _, _}, Rpc.classify(junk)), inspect(junk)
      end
    end
  end

  describe "codes and envelopes" do
    test "the JSON-RPC error codes" do
      assert Rpc.code(:parse_error) == -32_700
      assert Rpc.code(:invalid_request) == -32_600
      assert Rpc.code(:method_not_found) == -32_601
      assert Rpc.code(:invalid_params) == -32_602
      assert Rpc.code(:internal_error) == -32_603
      assert_raise KeyError, fn -> Rpc.code(:other) end
    end

    test "result and error envelopes" do
      assert Rpc.result_envelope(5, %{"a" => 1}) == %{
               "jsonrpc" => "2.0",
               "id" => 5,
               "result" => %{"a" => 1}
             }

      assert Rpc.error_envelope("x", -32_601, "No.") == %{
               "jsonrpc" => "2.0",
               "id" => "x",
               "error" => %{"code" => -32_601, "message" => "No."}
             }

      assert %{"id" => nil} = Rpc.error_envelope(nil, -32_700, "Parse error")
    end
  end

  describe "sending" do
    test "send_json sends JSON, never cached" do
      conn = :post |> conn("/") |> Rpc.send_json(200, Rpc.result_envelope(1, %{}))

      assert conn.status == 200
      assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert ["no-store"] = get_resp_header(conn, "cache-control")
      assert JSON.decode!(conn.resp_body) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      refute conn.halted
    end

    test "send_error sends the status and the error body, and halts" do
      conn = :post |> conn("/") |> Rpc.send_error(400, nil, :parse_error, "Parse error.")

      assert conn.halted
      assert conn.status == 400

      assert JSON.decode!(conn.resp_body) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_700, "message" => "Parse error."}
             }
    end

    test "accepted is a 202 with an empty body" do
      conn = :post |> conn("/") |> Rpc.accepted()

      assert conn.status == 202
      assert conn.resp_body == ""
    end
  end
end
