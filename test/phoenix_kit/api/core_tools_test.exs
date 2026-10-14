defmodule PhoenixKit.API.CoreToolsTest do
  @moduledoc """
  `system.get_identity`: a tool core ships itself, called the way a
  client does, through authentication and the executor.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.CoreTools
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Users.Permissions

  @read "testkit.items:read"
  @write "testkit.items:write"

  setup do
    setup_api()
  end

  defp identity(token) do
    :post
    |> api_conn("/", token: token)
    |> Auth.call(Auth.init(audience: :admin))
    |> then(&Executor.call(&1, :admin, "system.get_identity", %{}))
  end

  describe "tools/0" do
    test "declares system.get_identity: admin, no scope, read-only" do
      assert %Tool{} = tool = Enum.find(CoreTools.tools(), &(&1.name == "system.get_identity"))

      assert tool.name == "system.get_identity"
      assert tool.audience == :admin
      assert tool.scope == nil
      assert tool.permission == nil
      assert tool.annotations.read_only
      assert tool.handler == {CoreTools, :get_identity}
      assert tool.input_schema["additionalProperties"] == false
    end
  end

  describe "system.get_identity" do
    test "tells the key, its owner, the effective scopes and the tools they unlock" do
      {owner, _role} = user_with(["dashboard", "settings"])
      {key, token} = issue_key(owner, [@read], %{name: "Accounting"})

      conn = identity(token)

      assert conn.status == 200
      body = json(conn)

      assert %{"prefix" => prefix, "name" => "Accounting", "requires_approval" => false} =
               body["key"]

      assert prefix == key.prefix
      assert %{"id" => id, "email" => email, "service_user" => false} = body["owner"]
      assert id == owner.uuid
      assert email == owner.email

      assert body["scopes"] == [@read]

      tools = Map.new(body["tools"], &{&1["name"], &1})
      assert %{"scope" => @read, "read_only" => true} = tools["testkit.read_items"]
      assert %{"scope" => nil, "read_only" => true} = tools["system.get_identity"]
      refute Map.has_key?(tools, "testkit.write_item")
    end

    test "reports the expiry as ISO 8601 and the approval flag of the key" do
      {owner, _role} = user_with(["dashboard"])

      expires_at =
        DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)

      {_key, token} =
        issue_key(owner, [@read], %{expires_at: expires_at, requires_approval: true})

      assert %{"expires_at" => iso, "requires_approval" => true} =
               identity(token) |> json() |> Map.fetch!("key")

      assert iso == DateTime.to_iso8601(expires_at)
    end

    test "tells a service user owner apart" do
      {role, _permissions} = KeyTestSupport.role_with(["dashboard"])
      service = KeyTestSupport.service_user_with([role.name])

      {_key, token} =
        KeyTestSupport.create_key!(service, KeyTestSupport.scope_of(owner_user()), %{
          scopes: [@read]
        })

      assert %{"id" => id, "service_user" => true} =
               identity(token) |> json() |> Map.fetch!("owner")

      assert id == service.uuid
    end

    test "lists only the scopes the owner still holds" do
      {owner, role} = user_with(["dashboard", "settings"])
      {_key, token} = issue_key(owner, [@read, @write])

      assert json(identity(token))["scopes"] |> Enum.sort() == [@read, @write]

      assert :ok = Permissions.revoke_permission(role.uuid, "settings")

      body = json(identity(token))
      assert body["scopes"] == [@read]
      refute Enum.any?(body["tools"], &(&1["name"] == "testkit.write_item"))
    end

    test "works for a key with no scopes at all" do
      {owner, _role} = user_with(["dashboard"])
      {_key, token} = issue_key(owner, [])

      body = token |> identity() |> json()

      assert body["scopes"] == []

      assert ["system.get_approval", "system.get_identity"] =
               body["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    end

    test "is a read: it writes no api.request entry" do
      {owner, _role} = user_with(["dashboard"])
      {_key, token} = issue_key(owner, [])

      identity(token)

      assert Repo.aggregate(
               from(e in PhoenixKit.Activity.Entry, where: e.action == "api.request"),
               :count
             ) == 0
    end
  end
end
