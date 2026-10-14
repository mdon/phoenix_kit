defmodule PhoenixKit.API.RESTFlowTest do
  @moduledoc """
  The dangerous-operation flow through the REST plug: the `Idempotency-Key` header,
  a preview and its confirmation, and the CORS headers browser agents need.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiFlowHarness
  import PhoenixKit.Test.ApiHarness, only: [api_conn: 3, json: 1]
  import Plug.Conn

  alias PhoenixKit.API.REST
  alias PhoenixKit.Test.ApiFlowStore

  setup do
    setup_flow()
    agent = agent(requires_approval: false)
    %{token: agent.token}
  end

  defp admin(conn), do: REST.call(conn, REST.init(audience: :admin))
  defp public(conn), do: REST.call(conn, REST.init(audience: :public))

  defp key,
    do:
      "rest-key-" <>
        String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 12, "0")

  test "the Idempotency-Key header makes a retry safe", %{token: token} do
    headers = [{"idempotency-key", key()}]

    post = fn ->
      :post
      |> api_conn("/flowkit.touch_item", token: token, headers: headers, body: %{"name" => "x"})
      |> admin()
    end

    first = post.()
    second = post.()

    assert first.status == 200 and second.status == 200
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "idempotent-replayed") == ["true"]
    assert ApiFlowStore.calls() == 1
  end

  test "a dangerous call is previewed, then confirmed with the code, over REST", %{token: token} do
    first =
      :post |> api_conn("/flowkit.delete_items", token: token, body: %{"ids" => ["a"]}) |> admin()

    assert first.status == 200

    assert %{"executed" => false, "status" => "confirmation_required", "confirm_token" => code} =
             json(first)

    assert ApiFlowStore.items()["a"] == 100

    second =
      :post
      |> api_conn("/flowkit.delete_items",
        token: token,
        body: %{"ids" => ["a"], "confirm_token" => code}
      )
      |> admin()

    assert second.status == 200
    assert json(second) == %{"deleted" => 1}
    refute Map.has_key?(ApiFlowStore.items(), "a")
  end

  test "a bad confirmation code is a 409 problem document", %{token: token} do
    conn =
      :post
      |> api_conn("/flowkit.delete_items",
        token: token,
        body: %{"ids" => ["a"], "confirm_token" => "x"}
      )
      |> admin()

    assert conn.status == 409
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    assert %{"code" => "confirm_token_invalid", "context" => %{"preview" => %{}}} = json(conn)
  end

  test "the public preflight allows the Idempotency-Key header" do
    conn = :options |> api_conn("/flowkit.public_write", []) |> public()

    assert conn.status == 204

    assert ["content-type, idempotency-key"] =
             get_resp_header(conn, "access-control-allow-headers")
  end

  test "public answers expose the headers a browser agent reads" do
    conn = :post |> api_conn("/flowkit.public_write", body: %{"text" => "hi"}) |> public()

    assert conn.status == 200
    assert [exposed] = get_resp_header(conn, "access-control-expose-headers")

    for name <- ["idempotent-replayed", "ratelimit-remaining", "retry-after"],
        do: assert(exposed =~ name)
  end

  test "the admin audience still sends no CORS headers", %{token: token} do
    conn =
      :post |> api_conn("/flowkit.touch_item", token: token, body: %{"name" => "x"}) |> admin()

    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-expose-headers") == []
  end
end
