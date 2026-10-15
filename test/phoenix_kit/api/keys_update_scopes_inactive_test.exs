defmodule PhoenixKit.API.KeysUpdateScopesInactiveTest do
  @moduledoc """
  `PhoenixKit.API.Keys.update_scopes/3` and the scopes the owner cannot use right now (their
  module is switched off): they stay on the key, grant nothing, and an edit never drops them.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth

  defmodule SwitchableModule do
    @moduledoc false
    @flag {__MODULE__, :enabled}

    def scope, do: "switchfake.things:read"
    def switch(on?), do: :persistent_term.put(@flag, on?)
    def enabled?, do: :persistent_term.get(@flag, true)

    def api_tools do
      [
        Tool.new!(
          name: "switchfake.list_things",
          audience: :admin,
          scope: scope(),
          permission: "media",
          handler: {__MODULE__, :run}
        )
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  setup do
    register_fake_module!()
    ModuleRegistry.register(SwitchableModule)
    SwitchableModule.switch(true)

    on_exit(fn ->
      ModuleRegistry.unregister(SwitchableModule)
      :persistent_term.erase({SwitchableModule, :enabled})
    end)

    start_key_cache!()

    {holder, _role, scope} = api_holder(["media", "media.manage"])
    off = SwitchableModule.scope()
    {key, token} = create_key!(holder, scope, %{scopes: [read_scope(), off]})

    %{holder: holder, scope: scope, key: key, token: token, off: off}
  end

  defp entries(key) do
    Repo.all(
      from(e in Entry,
        where: e.action == "api.key_scopes_updated" and e.resource_uuid == ^key.uuid
      )
    )
  end

  test "a scope of a switched-off module stays when the key is saved without it", ctx do
    SwitchableModule.switch(false)
    refute ctx.off in Keys.allowed_scopes_for(ctx.holder)

    assert {:ok, same} = Keys.update_scopes(ctx.key, [read_scope()], ctx.scope)
    assert same.scopes == [read_scope(), ctx.off]
    assert Repo.get!(Key, ctx.key.uuid).scopes == [read_scope(), ctx.off]
    assert entries(ctx.key) == []
  end

  test "a save that only reorders the stored scopes writes and logs nothing", ctx do
    {key, _} = create_key!(ctx.holder, ctx.scope, %{scopes: [ctx.off, read_scope()]})
    SwitchableModule.switch(false)

    # The merge-back would give [read, off]: the same set in another order.
    assert {:ok, same} = Keys.update_scopes(key, [read_scope()], ctx.scope)
    assert same.scopes == [ctx.off, read_scope()]
    assert Repo.get!(Key, key.uuid).scopes == [ctx.off, read_scope()]
    assert entries(key) == []
  end

  test "a blocked owner has every scope inactive, so saving an empty list changes nothing", ctx do
    {:ok, _} = Auth.update_user_status(ctx.holder, %{is_active: false})
    assert Keys.effective_scopes(ctx.key) == []

    assert {:ok, same} = Keys.update_scopes(ctx.key, [], ctx.scope)
    assert same.scopes == [read_scope(), ctx.off]
    assert Repo.get!(Key, ctx.key.uuid).scopes == [read_scope(), ctx.off]
    assert entries(ctx.key) == []
  end

  test "an edit that changes the active scopes keeps the inactive ones", ctx do
    SwitchableModule.switch(false)

    assert {:ok, updated} = Keys.update_scopes(ctx.key, [write_scope()], ctx.scope)
    assert updated.scopes == [write_scope(), ctx.off]

    assert {:ok, emptied} = Keys.update_scopes(updated, [], ctx.scope)
    assert emptied.scopes == [ctx.off]
    assert Repo.get!(Key, ctx.key.uuid).scopes == [ctx.off]
  end

  test "an inactive scope sent back by the form is not a new scope", ctx do
    SwitchableModule.switch(false)

    assert {:ok, updated} =
             Keys.update_scopes(ctx.key, [write_scope(), ctx.off, read_scope()], ctx.scope)

    assert updated.scopes == [write_scope(), ctx.off, read_scope()]
  end

  test "a scope newly added must be one the owner can use right now", ctx do
    {key, _} = create_key!(ctx.holder, ctx.scope, %{scopes: [read_scope()]})
    SwitchableModule.switch(false)

    assert {:error, :invalid_scopes} =
             Keys.update_scopes(key, [read_scope(), ctx.off], ctx.scope)

    assert {:error, :invalid_scopes} =
             Keys.update_scopes(ctx.key, [read_scope(), "ghost.things:read"], ctx.scope)

    assert Repo.get!(Key, key.uuid).scopes == [read_scope()]
    assert Repo.get!(Key, ctx.key.uuid).scopes == [read_scope(), ctx.off]
  end

  test "an inactive scope grants nothing and works again when the module is switched back on",
       ctx do
    assert {:ok, actor} = Keys.verify(ctx.token, nil)
    assert ctx.off in actor.scopes

    SwitchableModule.switch(false)
    refute ctx.off in Keys.effective_scopes(Repo.get!(Key, ctx.key.uuid))

    assert {:ok, _} = Keys.update_scopes(ctx.key, [], ctx.scope)
    assert Keys.effective_scopes(Repo.get!(Key, ctx.key.uuid)) == []

    SwitchableModule.switch(true)
    stored = Repo.get!(Key, ctx.key.uuid)
    assert Keys.effective_scopes(stored) == [ctx.off]
    assert {:ok, actor} = Keys.verify(ctx.token, nil)
    assert actor.scopes == [ctx.off]
  end
end
