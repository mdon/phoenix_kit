defmodule PhoenixKit.API.ServiceUsersKeysTest do
  @moduledoc """
  A service user owns an API key, which its roles limit.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.ServiceUsers

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  describe "with keys" do
    test "a service user owns a key limited by its roles", ctx do
      {role, _} = role_with(["media"])
      {:ok, service} = ServiceUsers.create(ctx.owner_scope, %{roles: [role.name]})

      assert {:error, :invalid_scopes} =
               Keys.create_key(service, ctx.owner_scope, %{
                 name: "Too much",
                 scopes: [write_scope()]
               })

      assert {:ok, key, token} =
               Keys.create_key(service, ctx.owner_scope, %{name: "Robot", scopes: [read_scope()]})

      assert key.user_uuid == service.uuid
      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.user_uuid == service.uuid
      assert actor.scopes == [read_scope()]
    end

    test "an api holder can only own a key through a service user within their rights" do
      {_creator, _role, scope} = api_holder(["media"])
      {small, _} = role_with(["media"])
      {:ok, service} = ServiceUsers.create(scope, %{roles: [small.name]})

      assert {:ok, _key, _token} =
               Keys.create_key(service, scope, %{name: "Robot", scopes: [read_scope()]})

      # A more powerful service user, made by someone with wider rights.
      {big, _} = role_with(["media", "media.manage"])
      {:ok, powerful} = ServiceUsers.create(scope_of(owner_user()), %{roles: [big.name]})

      assert {:error, :owner_not_allowed} =
               Keys.create_key(powerful, scope, %{name: "Robot", scopes: [read_scope()]})
    end
  end
end
