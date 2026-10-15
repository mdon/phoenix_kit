defmodule PhoenixKit.API.AccessTest do
  @moduledoc """
  `PhoenixKit.API.Access.fresh_scope/1`: the rights of a person, read again from the
  database, for an event that changes something.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Access
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  setup do
    register_fake_module!()
    :ok
  end

  test "an Owner gets a scope" do
    owner = owner_user()
    assert {:ok, %Scope{} = fresh} = Access.fresh_scope(scope_of(owner))
    assert Scope.owner?(fresh)
  end

  test "a person who holds api gets a scope built from the database now" do
    {user, _role, scope} = api_holder(["media"])

    assert {:ok, fresh} = Access.fresh_scope(scope)
    assert Scope.user_uuid(fresh) == user.uuid
    assert Scope.can?(fresh, "api")
    assert Scope.can?(fresh, "media")
  end

  test "an api permission taken away since the scope was built is noticed" do
    {_user, role, scope} = api_holder(["media"])
    assert Scope.can?(scope, "api")

    assert :ok = Permissions.revoke_permission(role.uuid, "api")

    assert :error = Access.fresh_scope(scope)
  end

  test "a person who was blocked is refused" do
    {user, _role, scope} = api_holder(["media"])
    {:ok, _} = Auth.update_user_status(user, %{is_active: false})

    assert :error = Access.fresh_scope(scope)
  end

  test "a person who was deleted is refused" do
    {user, _role, scope} = api_holder(["media"])
    Repo.delete!(user)

    assert :error = Access.fresh_scope(scope)
  end

  test "nothing, an anonymous scope and a person without api are refused" do
    assert :error = Access.fresh_scope(nil)
    assert :error = Access.fresh_scope(Scope.for_user(nil))
    assert :error = Access.fresh_scope(scope_of(register_user!()))
  end
end
