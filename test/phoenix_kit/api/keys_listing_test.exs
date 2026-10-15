defmodule PhoenixKit.API.KeysListingTest do
  @moduledoc """
  `PhoenixKit.API.Keys.list_keys/1` and `token_prefix/1`.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Users.Auth.Scope

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  describe "list_keys/1" do
    test "an Owner sees every key, newest first; an api holder only the keys they created", ctx do
      {_a, _role, scope_a} = api_holder(["media"])
      {_b, _role, scope_b} = api_holder(["media"])
      {key_a, _} = create_key!(scope_a.user, scope_a)
      {key_b, _} = create_key!(scope_b.user, scope_b)
      {key_o, _} = create_key!(ctx.owner, ctx.owner_scope)

      assert Enum.map(Keys.list_keys(scope_a), & &1.uuid) == [key_a.uuid]
      assert Enum.map(Keys.list_keys(scope_b), & &1.uuid) == [key_b.uuid]

      owner_list = Enum.map(Keys.list_keys(ctx.owner_scope), & &1.uuid)

      assert [key_o.uuid, key_b.uuid, key_a.uuid] ==
               Enum.filter(owner_list, &(&1 in [key_a.uuid, key_b.uuid, key_o.uuid]))
    end

    test "a user without api sees none, and an anonymous scope sees none", ctx do
      {user, _role} = user_without_api(["media"])
      create_key!(ctx.owner, ctx.owner_scope)

      assert Keys.list_keys(scope_of(user)) == []
      assert Keys.list_keys(%Scope{}) == []
    end

    test "an api holder sees the keys they created for a service user too" do
      {_creator, _role, scope} = api_holder(["media"])
      {service_role, _} = role_with(["media"])
      service = service_user_with([service_role.name], scope)
      {key, _} = create_key!(service, scope)

      assert [%Key{uuid: uuid}] = Keys.list_keys(scope)
      assert uuid == key.uuid
    end
  end

  describe "token_prefix/1" do
    test "token_prefix/1 reads the prefix of a token" do
      assert Keys.token_prefix("pk_0123abcd_secret") == "0123abcd"
      assert Keys.token_prefix("garbage") == nil
    end
  end
end
