defmodule PhoenixKit.API.ServiceUsersListTest do
  @moduledoc """
  `PhoenixKit.API.ServiceUsers.list/1`: which service users a person may see and
  hand keys to. An Owner sees all of them; any other holder of `api` sees the
  ones they made; someone without `api` sees none.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.ServiceUsers

  defp operator do
    {user, _role} = KeyTestSupport.user_with(["api", "media"])
    {user, KeyTestSupport.scope_of(user)}
  end

  defp make_service_user!(scope, name) do
    roles = scope |> ServiceUsers.allowed_roles() |> Enum.take(1) |> Enum.map(& &1.name)
    {:ok, user} = ServiceUsers.create(scope, %{name: name, roles: roles})
    user
  end

  test "an operator sees the service users they made, and only those" do
    {_a, scope_a} = operator()
    {_b, scope_b} = operator()
    mine = make_service_user!(scope_a, "Mine")
    theirs = make_service_user!(scope_b, "Theirs")

    assert Enum.map(ServiceUsers.list(scope_a), & &1.uuid) == [mine.uuid]
    assert Enum.map(ServiceUsers.list(scope_b), & &1.uuid) == [theirs.uuid]
  end

  test "the Owner sees every service user" do
    {_a, scope_a} = operator()
    {_b, scope_b} = operator()
    one = make_service_user!(scope_a, "One")
    two = make_service_user!(scope_b, "Two")

    owner_scope = KeyTestSupport.scope_of(KeyTestSupport.owner_user())
    listed = Enum.map(ServiceUsers.list(owner_scope), & &1.uuid)

    assert one.uuid in listed
    assert two.uuid in listed
  end

  test "people are not service users, so a plain user is never listed" do
    {_a, scope_a} = operator()
    person = KeyTestSupport.register_user!()
    _bot = make_service_user!(scope_a, "Bot")

    owner_scope = KeyTestSupport.scope_of(KeyTestSupport.owner_user())

    assert Enum.all?(ServiceUsers.list(owner_scope), & &1.api_only)
    refute person.uuid in Enum.map(ServiceUsers.list(owner_scope), & &1.uuid)
  end

  test "a person without the api permission sees none" do
    {_a, scope_a} = operator()
    _bot = make_service_user!(scope_a, "Bot")
    {no_api, _role} = KeyTestSupport.user_with(["media"])

    assert ServiceUsers.list(KeyTestSupport.scope_of(no_api)) == []
  end

  test "an anonymous scope sees none" do
    assert ServiceUsers.list(%PhoenixKit.Users.Auth.Scope{}) == []
    assert ServiceUsers.list(nil) == []
  end
end
