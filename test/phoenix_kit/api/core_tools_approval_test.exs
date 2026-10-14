defmodule PhoenixKit.API.CoreToolsApprovalTest do
  @moduledoc """
  `system.get_approval`: an agent follows an operation that waits for a person. Called
  the way a client does, through authentication and the executor.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiFlowHarness
  import PhoenixKit.Test.ApiHarness, only: [api_conn: 3, json: 1]

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.CoreTools
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Test.ApiFlowStore

  @delete "flowkit.delete_items"

  setup do
    setup_flow()
    agent = agent()
    {:ok, row, :created} = queue(agent, @delete, %{"ids" => ["a", "b"]})
    %{agent: agent, row: row, owner_scope: KeyTestSupport.scope_of(KeyTestSupport.owner_user())}
  end

  defp get_approval(token, id) do
    :post
    |> api_conn("/", token: token)
    |> Auth.call(Auth.init(audience: :admin))
    |> then(&Executor.call(&1, :admin, "system.get_approval", %{"approval_id" => id}))
  end

  test "is declared: admin, no scope, no permission, read-only, an approval_id" do
    assert %Tool{} = tool = Enum.find(CoreTools.tools(), &(&1.name == "system.get_approval"))

    assert tool.audience == :admin
    assert tool.scope == nil
    assert tool.permission == nil
    assert tool.annotations.read_only
    assert tool.handler == {CoreTools, :get_approval}
    assert tool.input_schema["required"] == ["approval_id"]
    assert tool.input_schema["additionalProperties"] == false
  end

  test "a pending approval: its state, its preview and the time left, never its input", %{
    agent: agent,
    row: row
  } do
    conn = get_approval(agent.token, row.uuid)

    assert conn.status == 200

    assert %{
             "approval_id" => id,
             "status" => "pending",
             "tool" => @delete,
             "preview" => %{"totals" => %{"delete" => 2}},
             "expires_in_seconds" => seconds
           } = json(conn)

    assert id == row.uuid
    assert seconds > 0
    refute Map.has_key?(json(conn), "input")
  end

  test "an executed approval reports its result", %{agent: agent, row: row, owner_scope: scope} do
    {:ok, _done} = Approvals.approve(row.uuid, scope)

    assert %{"status" => "executed", "result" => %{"deleted" => 2}} =
             agent.token |> get_approval(row.uuid) |> json()
  end

  test "a rejected, a failed and a stale approval report their state", %{
    agent: agent,
    owner_scope: scope
  } do
    {:ok, rejected, :created} = queue(agent, @delete, %{"ids" => ["c"]})
    {:ok, _} = Approvals.reject(rejected.uuid, scope)
    assert %{"status" => "rejected"} = agent.token |> get_approval(rejected.uuid) |> json()

    {:ok, failing, :created} = queue(agent, "flowkit.progress_write", %{"fail" => true})
    {:ok, _} = Approvals.approve(failing.uuid, scope)

    assert %{
             "status" => "failed",
             "error" => %{"code" => "insufficient_stock"},
             "partial" => %{"done" => 1}
           } =
             agent.token |> get_approval(failing.uuid) |> json()

    {:ok, stale, :created} = queue(agent, @delete, %{"ids" => ["a"]})
    ApiFlowStore.put("a", 999)
    {:ok, _} = Approvals.approve(stale.uuid, scope)

    assert %{"status" => "stale", "error" => %{"code" => "stale"}} =
             agent.token |> get_approval(stale.uuid) |> json()
  end

  test "another key's approval, an unknown id and a malformed id are all not_found", %{
    agent: agent,
    row: row
  } do
    other = agent()

    for id <- [row.uuid, UUIDv7.generate(), "nope"] do
      token = if id == row.uuid, do: other.token, else: agent.token
      conn = get_approval(token, id)

      assert conn.status == 404, id
      assert json(conn)["code"] == "not_found"
    end
  end

  test "an id that is not a string is a validation error", %{agent: agent} do
    conn =
      :post
      |> api_conn("/", token: agent.token)
      |> Auth.call(Auth.init(audience: :admin))
      |> then(&Executor.call(&1, :admin, "system.get_approval", %{"approval_id" => 5}))

    assert conn.status == 422
  end

  test "it is a read: no api.request entry, and the control fields are refused", %{
    agent: agent,
    row: row
  } do
    get_approval(agent.token, row.uuid)

    assert Repo.aggregate(
             from(e in Entry,
               where: e.action == "api.request" and e.resource_uuid == ^agent.key.uuid
             ),
             :count
           ) == 0

    conn =
      :post
      |> api_conn("/", token: agent.token)
      |> Auth.call(Auth.init(audience: :admin))
      |> then(
        &Executor.call(&1, :admin, "system.get_approval", %{
          "approval_id" => row.uuid,
          "dry_run" => true
        })
      )

    assert conn.status == 422
  end

  test "a key with no scopes at all may call it", %{} do
    bare = agent(scopes: [])
    {:ok, row, :created} = queue(bare, @delete, %{"ids" => ["a"]})

    assert 200 == get_approval(bare.token, row.uuid).status
  end

  test "a pending approval past its time reads as expired", %{agent: agent, row: row} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(c in PhoenixKit.API.Confirm.Confirmation, where: c.uuid == ^row.uuid),
      set: [expires_at: past]
    )

    assert %{"status" => "expired"} = agent.token |> get_approval(row.uuid) |> json()
  end
end
