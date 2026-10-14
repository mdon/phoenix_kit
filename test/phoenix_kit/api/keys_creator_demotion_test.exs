defmodule PhoenixKit.API.KeysCreatorDemotionTest do
  @moduledoc """
  The creator's authority over a service user's key does not outlive their
  rights. `Keys.create_key/3` lets a person create a key for a service user only
  while they hold every permission the service user holds; `update_scopes/3`
  and `rotate/3` must keep to the same bounds, or demoting an `api` holder (who
  keeps `api`) would leave them able to grow or re-mint the key.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  setup do
    register_fake_module!()
    start_key_cache!()

    {creator, creator_role} = user_with(["media", "media.manage"])
    {svc_role, _} = role_with(["media", "media.manage"])
    {:ok, svc} = ServiceUsers.create(scope_of(creator), %{roles: [svc_role.name]})
    {key, _token} = create_key!(svc, scope_of(creator), %{scopes: [read_scope()]})

    %{creator: creator, creator_role: creator_role, svc: svc, svc_role: svc_role, key: key}
  end

  defp demote!(ctx, permission) do
    :ok = Permissions.revoke_permission(ctx.creator_role.uuid, permission)
    demoted = scope_of(ctx.creator)
    refute Scope.can?(demoted, permission)
    assert Scope.can?(demoted, "api")
    demoted
  end

  describe "a creator demoted below the service user" do
    test "cannot create a key for it (the baseline)", ctx do
      demoted = demote!(ctx, "media.manage")

      assert {:error, :owner_not_allowed} =
               Keys.create_key(ctx.svc, demoted, %{name: "new", scopes: [write_scope()]})
    end

    test "cannot add a scope whose permission they no longer hold", ctx do
      demoted = demote!(ctx, "media.manage")

      assert {:error, :invalid_scopes} =
               Keys.update_scopes(ctx.key, [read_scope(), write_scope()], demoted)

      assert Keys.get_key(ctx.key.uuid).scopes == [read_scope()]
    end

    test "can still keep the scopes the key has, and take scopes off", ctx do
      {:ok, widened} =
        Keys.update_scopes(ctx.key, [read_scope(), write_scope()], scope_of(ctx.creator))

      demoted = demote!(ctx, "media.manage")

      assert {:ok, same} = Keys.update_scopes(widened, [read_scope(), write_scope()], demoted)
      assert Enum.sort(same.scopes) == Enum.sort([read_scope(), write_scope()])

      assert {:ok, narrowed} = Keys.update_scopes(widened, [read_scope()], demoted)
      assert narrowed.scopes == [read_scope()]
    end

    test "cannot rotate the key (no fresh token for the service user)", ctx do
      demoted = demote!(ctx, "media.manage")

      assert {:error, :owner_not_allowed} = Keys.rotate(ctx.key, 0, demoted)
      assert Keys.get_key(ctx.key.uuid).revoked_at == nil
    end

    test "can still revoke the key", ctx do
      demoted = demote!(ctx, "media.manage")
      assert {:ok, _key} = Keys.revoke(ctx.key, demoted.user.uuid)
    end
  end

  describe "a service user widened after the key was made" do
    test "the creator cannot add a scope backed by a permission they lack", ctx do
      creator_scope = scope_of(ctx.creator)
      refute Scope.can?(creator_scope, "jobs.manage")
      {:ok, _} = Permissions.grant_permission(ctx.svc_role.uuid, "jobs.manage")

      assert {:error, :invalid_scopes} =
               Keys.update_scopes(ctx.key, [read_scope(), run_scope()], creator_scope)
    end

    test "nor rotate the key", ctx do
      {:ok, _} = Permissions.grant_permission(ctx.svc_role.uuid, "jobs.manage")

      assert {:error, :owner_not_allowed} = Keys.rotate(ctx.key, 0, scope_of(ctx.creator))
    end
  end

  describe "an editor who holds what the service user holds" do
    test "the creator adds a scope and rotates the key", ctx do
      creator_scope = scope_of(ctx.creator)

      assert {:ok, key} =
               Keys.update_scopes(ctx.key, [read_scope(), write_scope()], creator_scope)

      assert write_scope() in key.scopes
      assert {:ok, _new_key, _token} = Keys.rotate(key, 0, creator_scope)
    end

    test "the Owner adds a scope and rotates the key", ctx do
      owner_scope = scope_of(owner_user())

      assert {:ok, key} = Keys.update_scopes(ctx.key, [read_scope(), write_scope()], owner_scope)
      assert {:ok, _new_key, _token} = Keys.rotate(key, 0, owner_scope)
    end

    test "a person edits their own key whatever role is active" do
      {user, _role} = user_with(["media", "media.manage"])
      {key, _token} = create_key!(user, scope_of(user), %{scopes: [read_scope()]})

      assert {:ok, key} = Keys.update_scopes(key, [read_scope(), write_scope()], scope_of(user))
      assert {:ok, _new_key, _token} = Keys.rotate(key, 0, scope_of(user))
    end
  end

  describe "allowed_scopes_for/2" do
    test "narrows the owner's scopes to what the editor holds", ctx do
      assert write_scope() in Keys.allowed_scopes_for(ctx.svc)
      assert write_scope() in Keys.allowed_scopes_for(ctx.svc, scope_of(ctx.creator))

      demoted = demote!(ctx, "media.manage")
      refute write_scope() in Keys.allowed_scopes_for(ctx.svc, demoted)
      assert read_scope() in Keys.allowed_scopes_for(ctx.svc, demoted)
    end

    test "is the owner's own list when the owner edits", ctx do
      assert Keys.allowed_scopes_for(ctx.creator, scope_of(ctx.creator)) ==
               Keys.allowed_scopes_for(ctx.creator)
    end
  end
end
