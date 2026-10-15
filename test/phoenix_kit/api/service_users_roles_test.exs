defmodule PhoenixKit.API.ServiceUsersRolesTest do
  @moduledoc """
  `PhoenixKit.API.ServiceUsers.allowed_roles/1`: which roles a creator may give
  to a service user.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.ServiceUsers

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  describe "allowed_roles/1" do
    test "an Owner may give every role but Owner", ctx do
      names = ctx.owner_scope |> ServiceUsers.allowed_roles() |> Enum.map(& &1.name)

      refute "Owner" in names
      assert "Admin" in names
      assert "User" in names
    end

    test "an api holder gets only roles inside their own rights" do
      {_creator, _role, scope} = api_holder(["media"])
      {small, _} = role_with(["media"])
      {big, _} = role_with(["media", "media.manage"])

      names = scope |> ServiceUsers.allowed_roles() |> Enum.map(& &1.name)
      assert small.name in names
      refute big.name in names
      refute "Owner" in names
    end

    test "someone without api gets none" do
      {user, _role} = user_without_api(["media"])
      assert ServiceUsers.allowed_roles(scope_of(user)) == []
    end
  end
end
