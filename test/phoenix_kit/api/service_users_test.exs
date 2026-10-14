defmodule PhoenixKit.API.ServiceUsersTest do
  @moduledoc """
  `PhoenixKit.API.ServiceUsers`: who may create an `api_only` account, which
  roles it may hold, and that it can own a working key.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  defp service_user_count, do: Repo.aggregate(from(u in User, where: u.api_only == true), :count)

  describe "create/2" do
    test "an Owner creates an api_only account with the chosen roles", ctx do
      {role, _} = role_with(["media"])

      assert {:ok, %User{} = user} =
               ServiceUsers.create(ctx.owner_scope, %{
                 name: "Accounting robot",
                 roles: [role.name]
               })

      stored = Repo.get!(User, user.uuid)
      assert stored.api_only
      assert stored.is_active
      assert stored.confirmed_at
      assert stored.first_name == "Accounting robot"
      assert stored.created_by_uuid == ctx.owner.uuid
      assert stored.email == "api-#{user.uuid}@service.invalid"
      assert Roles.get_user_roles(stored) == [role.name]
    end

    test "the account has no password anyone could type" do
      {:ok, user} = ServiceUsers.create(scope_of(owner_user()), %{roles: []})

      refute User.valid_password?(user, "")
      refute User.valid_password?(user, "password")
      refute User.valid_password?(user, "ValidPassword123!")
      assert String.starts_with?(user.hashed_password, "$2b$")
    end

    test "the name is optional, trimmed and at most 100 characters", ctx do
      assert {:ok, %User{first_name: "API service user"}} =
               ServiceUsers.create(ctx.owner_scope, %{roles: []})

      assert {:ok, %User{first_name: "API service user"}} =
               ServiceUsers.create(ctx.owner_scope, %{name: "   ", roles: []})

      assert {:ok, %User{first_name: "Robot"}} =
               ServiceUsers.create(ctx.owner_scope, %{name: "  Robot ", roles: []})

      before = service_user_count()

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceUsers.create(ctx.owner_scope, %{name: String.duplicate("n", 101), roles: []})

      assert %{first_name: [_ | _]} = errors_on(cs)
      assert service_user_count() == before
    end

    test "writes a permanent api.service_user_created entry", ctx do
      {role, _} = role_with(["media"])
      {:ok, user} = ServiceUsers.create(ctx.owner_scope, %{name: "Robot", roles: [role.name]})

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where: e.action == "api.service_user_created" and e.resource_uuid == ^user.uuid
                 )
               )

      assert entry.module == "api"
      assert entry.permanent
      assert entry.actor_uuid == ctx.owner.uuid
      assert entry.metadata["roles"] == [role.name]
      assert entry.metadata["name"] == "Robot"
    end

    test "refuses a creator who does not hold api, and creates nothing" do
      {user, role} = user_without_api(["media"])
      before = service_user_count()

      assert {:error, :forbidden} = ServiceUsers.create(scope_of(user), %{roles: [role.name]})

      assert {:error, :forbidden} =
               ServiceUsers.create(%PhoenixKit.Users.Auth.Scope{}, %{roles: []})

      assert service_user_count() == before
    end

    test "gives roles within the creator's rights and no others" do
      {_creator, _role, scope} = api_holder(["media"])
      {small, _} = role_with(["media"])
      {same, _} = role_with(["media", "api"])
      {big, _} = role_with(["media", "media.manage"])
      {other, _} = role_with(["jobs"])

      assert {:ok, _} = ServiceUsers.create(scope, %{roles: [small.name]})
      assert {:ok, _} = ServiceUsers.create(scope, %{roles: [small.name, same.name]})

      before = service_user_count()
      assert {:error, :role_not_allowed} = ServiceUsers.create(scope, %{roles: [big.name]})
      assert {:error, :role_not_allowed} = ServiceUsers.create(scope, %{roles: [other.name]})
      # One bad role refuses the whole request, even after a good one.
      assert {:error, :role_not_allowed} =
               ServiceUsers.create(scope, %{roles: [small.name, big.name]})

      assert service_user_count() == before
    end

    test "never gives the Owner role, even to an Owner", ctx do
      before = service_user_count()

      assert {:error, :role_not_allowed} =
               ServiceUsers.create(ctx.owner_scope, %{roles: ["Owner"]})

      assert service_user_count() == before
    end

    test "refuses unknown roles and a roles value that is not a list", ctx do
      assert {:error, :role_not_allowed} =
               ServiceUsers.create(ctx.owner_scope, %{roles: ["No such role"]})

      assert {:error, :role_not_allowed} = ServiceUsers.create(ctx.owner_scope, %{roles: "Admin"})
      assert {:error, :role_not_allowed} = ServiceUsers.create(ctx.owner_scope, %{roles: [nil]})
    end
  end
end
