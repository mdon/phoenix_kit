defmodule PhoenixKit.Test.ApiFlowHarness do
  @moduledoc """
  Setup for the tests of the dangerous-operation flow, layered on
  `PhoenixKit.Test.ApiHarness` (switches, key cache, users, keys, requests).

  `setup_flow/1` does what `ApiHarness.setup_api/1` does and also starts the store and
  registers `PhoenixKit.Test.ApiFlowTools`. `agent/1` makes a user with the `settings`
  and `dashboard` permissions and a key of theirs holding the three `flowkit` scopes.
  `queue/4` turns a tool call into a pending approval by running the real handler as a
  dry run, as the danger gate does.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Canonical
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.Registry
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.ApiFlowStore
  alias PhoenixKit.Test.ApiFlowTools
  alias PhoenixKit.Test.ApiHarness

  @scopes ["flowkit.items:read", "flowkit.items:write", "flowkit.items:delete"]

  @doc "The three scopes of the flowkit tools."
  def scopes, do: @scopes

  @doc """
  Starts the key cache, switches the API on, registers `ApiTools` and `ApiFlowTools`
  and starts the store with items `a` 100, `b` 200, `c` 300. Same options as
  `ApiHarness.setup_api/1`.
  """
  def setup_flow(opts \\ []) do
    ApiHarness.setup_api(opts)
    start_supervised!(ApiFlowStore)
    :ok = ModuleRegistry.register(ApiFlowTools)
    ApiFlowTools.set_enabled(true)

    on_exit(fn ->
      ModuleRegistry.unregister(ApiFlowTools)
      ApiFlowTools.set_enabled(true)
    end)

    ApiFlowStore.reset(%{"a" => 100, "b" => 200, "c" => 300})
    :ok
  end

  @doc """
  A user who holds `settings`, `dashboard` and `api`, and a key of theirs with the
  flowkit scopes. Options: `requires_approval: true` (the default), `scopes:`.
  Returns `%{owner, role, key, token, actor, scope}`.
  """
  def agent(opts \\ []) do
    {owner, role} = ApiHarness.user_with(["settings", "dashboard"])

    {key, token} =
      ApiHarness.issue_key(owner, Keyword.get(opts, :scopes, @scopes), %{
        name: "agent",
        requires_approval: Keyword.get(opts, :requires_approval, true)
      })

    {:ok, actor} = Confirm.live_actor(key.uuid)

    %{
      owner: owner,
      role: role,
      key: key,
      token: token,
      actor: actor,
      scope: KeyTestSupport.scope_of(owner)
    }
  end

  @doc """
  Queues `input` for `tool_name` as `agent` would: runs the real handler as a dry run
  for the preview and the fingerprint, then calls `Approvals.request/2`.
  """
  def queue(agent, tool_name, input, opts \\ []) do
    {:ok, tool} = Registry.find(tool_name, :admin)
    {module, function} = tool.handler

    ctx = %{
      actor: agent.actor,
      scopes: agent.actor.scopes,
      audience: :admin,
      language: "en",
      currency: nil,
      hosts: [],
      base_url: "https://shop.example",
      request_id: "req-test",
      dry_run?: true,
      approved_by_uuid: nil,
      confirmation_uuid: nil,
      progress: fn _partial -> :ok end
    }

    {:preview, preview, fingerprint} = apply(module, function, [input, ctx])

    Approvals.request(
      %{
        actor: agent.actor,
        tool: tool_name,
        input: input,
        input_hash: Canonical.hash(tool_name, input),
        preview: preview,
        fingerprint: fingerprint,
        context: %{
          "language" => "en",
          "currency" => nil,
          "hosts" => [],
          "base_url" => "https://shop.example",
          "request_id" => "req-test"
        }
      },
      Keyword.get(opts, :now, DateTime.utc_now())
    )
  end
end
