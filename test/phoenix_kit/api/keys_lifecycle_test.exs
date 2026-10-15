defmodule PhoenixKit.API.KeysLifecycleTest do
  @moduledoc """
  Revoking and rotating keys, who may see and manage them, and the scopes a key
  carries (scopes are filtered by the owner's live permissions on every use).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  defp entries(action, key) do
    Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^key.uuid))
  end

  describe "revoke/2" do
    test "stops the key on the next request, even though its row is cached", ctx do
      {key, token} = create_key!(ctx.owner, ctx.owner_scope)
      assert {:ok, _} = Keys.verify(token, nil)

      assert {:ok, revoked} = Keys.revoke(key, ctx.owner.uuid)
      assert %DateTime{} = revoked.revoked_at
      assert {:error, :revoked} = Keys.verify(token, nil)
    end

    test "writes one permanent api.key_revoked entry; revoking twice changes nothing", ctx do
      {key, _token} = create_key!(ctx.owner, ctx.owner_scope)

      assert {:ok, first} = Keys.revoke(key, ctx.owner.uuid)
      assert {:ok, second} = Keys.revoke(first, ctx.owner.uuid)
      assert second.revoked_at == first.revoked_at

      assert [entry] = entries("api.key_revoked", key)
      assert entry.module == "api"
      assert entry.permanent
      assert entry.actor_uuid == ctx.owner.uuid
      assert entry.metadata["key_prefix"] == key.prefix
    end

    test "revokes at once a key whose revocation was only scheduled", ctx do
      {key, token} = create_key!(ctx.owner, ctx.owner_scope)
      {:ok, _new, _new_token} = Keys.rotate(key, 24, ctx.owner_scope)
      assert {:ok, _} = Keys.verify(token, nil)

      scheduled = Keys.get_key(key.uuid)
      assert {:ok, _} = Keys.revoke(scheduled, ctx.owner.uuid)
      assert {:error, :revoked} = Keys.verify(token, nil)
    end

    test "a key whose row is gone is not found, not a crash", ctx do
      {key, _token} = create_key!(ctx.owner, ctx.owner_scope)
      Repo.delete!(key)

      assert {:error, :not_found} = Keys.revoke(key, ctx.owner.uuid)
      assert entries("api.key_revoked", key) == []
    end

    test "a stale struct cannot overwrite a revocation the row already has", ctx do
      {key, _token} = create_key!(ctx.owner, ctx.owner_scope)
      earlier = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(k in Key, where: k.uuid == ^key.uuid), set: [revoked_at: earlier])

      # `key` still says revoked_at: nil; the row is re-read.
      assert {:ok, revoked} = Keys.revoke(key, ctx.owner.uuid)
      assert revoked.revoked_at == earlier
      assert Repo.get!(Key, key.uuid).revoked_at == earlier
      assert entries("api.key_revoked", key) == []
    end
  end

  describe "rotate/3" do
    test "issues a new key with the same settings and keeps the old one for the grace period",
         ctx do
      expires_at = DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:second)

      {old, old_token} =
        create_key!(ctx.owner, ctx.owner_scope, %{
          name: "Accounting",
          scopes: [read_scope(), write_scope()],
          requires_approval: true,
          allowed_ips: ["203.0.113.0/24"],
          expires_at: expires_at
        })

      assert {:ok, %Key{} = new, new_token} = Keys.rotate(old, 2, ctx.owner_scope)

      refute new.uuid == old.uuid
      refute new.prefix == old.prefix
      refute new_token == old_token
      assert new.name == "Accounting"
      assert new.user_uuid == old.user_uuid
      assert new.created_by_uuid == old.created_by_uuid
      assert new.scopes == old.scopes
      assert new.requires_approval
      assert new.allowed_ips == ["203.0.113.0/24"]
      assert DateTime.compare(new.expires_at, expires_at) == :eq
      assert new.revoked_at == nil

      # Both tokens work during the grace period.
      assert {:ok, _} = Keys.verify(new_token, "203.0.113.5")
      assert {:ok, _} = Keys.verify(old_token, "203.0.113.5")

      retire_at = Repo.get!(Key, old.uuid).revoked_at
      assert_in_delta DateTime.diff(retire_at, DateTime.utc_now()), 2 * 3600, 10

      # When the grace period ends the old key is dead, the new one is not.
      Repo.update_all(from(k in Key, where: k.uuid == ^old.uuid),
        set: [
          revoked_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      Keys.Cache.invalidate(old.prefix)
      assert {:error, :revoked} = Keys.verify(old_token, "203.0.113.5")
      assert {:ok, _} = Keys.verify(new_token, "203.0.113.5")
    end

    test "a grace of 0 retires the old key at once", ctx do
      {old, old_token} = create_key!(ctx.owner, ctx.owner_scope)
      assert {:ok, _} = Keys.verify(old_token, nil)

      assert {:ok, _new, new_token} = Keys.rotate(old, 0, ctx.owner_scope)

      assert {:error, :revoked} = Keys.verify(old_token, nil)
      assert {:ok, _} = Keys.verify(new_token, nil)
    end

    test "writes a permanent api.key_rotated entry naming both keys", ctx do
      {old, _} = create_key!(ctx.owner, ctx.owner_scope)
      {:ok, new, _} = Keys.rotate(old, 6, ctx.owner_scope)

      assert [entry] = entries("api.key_rotated", old)
      assert entry.permanent
      assert entry.actor_uuid == ctx.owner.uuid
      assert entry.metadata["key_prefix"] == old.prefix
      assert entry.metadata["new_key_prefix"] == new.prefix
      assert entry.metadata["new_key_uuid"] == new.uuid
      assert entry.metadata["grace_hours"] == 6
    end

    test "the grace period is 0 to 24 hours", ctx do
      {old, _} = create_key!(ctx.owner, ctx.owner_scope)

      for bad <- [-1, 25, 1.5, nil, "2"] do
        assert {:error, :invalid_grace} = Keys.rotate(old, bad, ctx.owner_scope), inspect(bad)
      end

      assert Repo.aggregate(from(k in Key, where: k.name == ^old.name), :count) == 1
    end

    test "refuses a key that is already revoked or expired", ctx do
      {revoked, _} = create_key!(ctx.owner, ctx.owner_scope)
      {:ok, _} = Keys.revoke(revoked, ctx.owner.uuid)
      assert {:error, :revoked} = Keys.rotate(Keys.get_key(revoked.uuid), 1, ctx.owner_scope)

      {expiring, _} =
        create_key!(ctx.owner, ctx.owner_scope, %{
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      Repo.update_all(from(k in Key, where: k.uuid == ^expiring.uuid),
        set: [
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :expired} = Keys.rotate(Keys.get_key(expiring.uuid), 1, ctx.owner_scope)
    end

    test "a stale struct cannot revive a revoked key", ctx do
      {key, token} = create_key!(ctx.owner, ctx.owner_scope)
      {:ok, _} = Keys.revoke(Keys.get_key(key.uuid), ctx.owner.uuid)
      assert {:error, :revoked} = Keys.verify(token, nil)

      # `key` still says revoked_at: nil; the row is re-read.
      assert {:error, :revoked} = Keys.rotate(key, 2, ctx.owner_scope)

      assert {:error, :revoked} = Keys.verify(token, nil)
      assert Repo.aggregate(from(k in Key, where: k.name == ^key.name), :count) == 1
      assert entries("api.key_rotated", key) == []
    end

    test "a key whose row is gone is not found, not a crash", ctx do
      {key, _token} = create_key!(ctx.owner, ctx.owner_scope)
      Repo.delete!(key)

      assert {:error, :not_found} = Keys.rotate(key, 2, ctx.owner_scope)
      assert Repo.aggregate(from(k in Key, where: k.name == ^key.name), :count) == 0
    end

    test "a key that is already being retired is not rotated again", ctx do
      {key, token} = create_key!(ctx.owner, ctx.owner_scope)
      assert {:ok, _new, _new_token} = Keys.rotate(key, 1, ctx.owner_scope)
      retire_at = Repo.get!(Key, key.uuid).revoked_at

      # Neither the fresh row nor the stale struct may extend the retirement or
      # issue a third key.
      for stale_or_fresh <- [key, Keys.get_key(key.uuid)] do
        assert {:error, :rotation_pending} = Keys.rotate(stale_or_fresh, 24, ctx.owner_scope)
      end

      assert Repo.get!(Key, key.uuid).revoked_at == retire_at
      assert Repo.aggregate(from(k in Key, where: k.name == ^key.name), :count) == 2
      assert {:ok, _} = Keys.verify(token, nil)
    end

    test "the same struct rotated twice issues one new key", ctx do
      {key, _token} = create_key!(ctx.owner, ctx.owner_scope)

      assert {:ok, _new, _new_token} = Keys.rotate(key, 0, ctx.owner_scope)
      assert {:error, :revoked} = Keys.rotate(key, 0, ctx.owner_scope)

      assert Repo.aggregate(from(k in Key, where: k.name == ^key.name), :count) == 2
      assert length(entries("api.key_rotated", key)) == 1
    end

    test "only an Owner or the creator may rotate" do
      {_creator, _role, creator_scope} = api_holder(["media"])
      {_other, _role, other_scope} = api_holder(["media"])
      {key, _} = create_key!(creator_scope.user, creator_scope)

      assert {:error, :forbidden} = Keys.rotate(key, 1, other_scope)
      assert {:ok, _new, _token} = Keys.rotate(key, 1, creator_scope)

      # A key already being retired is not rotated again, so the Owner gets a fresh one.
      {other_key, _} = create_key!(creator_scope.user, creator_scope)

      assert {:ok, _new, _token} =
               Keys.rotate(Keys.get_key(other_key.uuid), 1, scope_of(owner_user()))
    end

    test "a holder who lost api can no longer rotate" do
      {_user, role, scope} = api_holder(["media"])
      {key, _} = create_key!(scope.user, scope)

      :ok = Permissions.revoke_permission(role.uuid, "api")
      assert {:error, :forbidden} = Keys.rotate(key, 1, scope_of(scope.user))
    end
  end

  defp cached?(key), do: match?(%Key{}, PhoenixKit.Cache.get(:api_keys, key.prefix))

  describe "update_scopes/3" do
    test "only an Owner or the creator may edit; anyone else is forbidden and nothing changes" do
      {_creator, _role, creator_scope} = api_holder(["media", "media.manage"])
      {_other, _role, other_scope} = api_holder(["media", "media.manage"])
      {key, _} = create_key!(creator_scope.user, creator_scope, %{scopes: [read_scope()]})
      wider = [read_scope(), write_scope()]

      assert {:error, :forbidden} = Keys.update_scopes(key, wider, other_scope)
      assert {:error, :forbidden} = Keys.update_scopes(key, wider, %Scope{})

      assert Repo.get!(Key, key.uuid).scopes == [read_scope()]
      assert entries("api.key_scopes_updated", key) == []
    end

    test "a forged struct neither widens what the stored key allows nor passes for its creator" do
      {_creator, _role, creator_scope} = api_holder(["media", "media.manage"])
      {_other, _role, other_scope} = api_holder(["media", "media.manage"])
      {key, _} = create_key!(creator_scope.user, creator_scope, %{scopes: [read_scope()]})

      # The exemption for scopes "already on the key" reads the stored row, not the struct.
      ghost = [read_scope(), "ghost.things:read"]
      forged_scopes = %{key | scopes: ghost}
      assert {:error, :invalid_scopes} = Keys.update_scopes(forged_scopes, ghost, creator_scope)

      # Authorization looks at the stored creator, not at the `created_by_uuid` the caller wrote.
      forged_creator = %Key{uuid: key.uuid, created_by_uuid: other_scope.user.uuid}
      wider = [read_scope(), write_scope()]
      assert {:error, :forbidden} = Keys.update_scopes(forged_creator, wider, other_scope)

      assert Repo.get!(Key, key.uuid).scopes == [read_scope()]
      assert entries("api.key_scopes_updated", key) == []
    end

    test "a holder who lost api can no longer edit" do
      {_user, role, scope} = api_holder(["media", "media.manage"])
      {key, _} = create_key!(scope.user, scope, %{scopes: [read_scope()]})

      :ok = Permissions.revoke_permission(role.uuid, "api")

      assert {:error, :forbidden} =
               Keys.update_scopes(key, [read_scope(), write_scope()], scope_of(scope.user))

      assert Repo.get!(Key, key.uuid).scopes == [read_scope()]
    end

    test "an Owner may edit any key, and the entry names the Owner as the actor", ctx do
      {holder, _role, scope} = api_holder(["media", "media.manage"])
      {key, _} = create_key!(holder, scope, %{scopes: [read_scope()]})

      assert {:ok, updated} = Keys.update_scopes(key, [write_scope()], ctx.owner_scope)
      assert updated.scopes == [write_scope()]

      assert [entry] = entries("api.key_scopes_updated", key)
      assert entry.actor_uuid == ctx.owner.uuid
    end

    test "stores the scopes, drops the cached row and the next verify sees them" do
      {holder, _role, scope} = api_holder(["media", "media.manage"])
      {key, token} = create_key!(holder, scope, %{scopes: [read_scope()]})

      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.scopes == [read_scope()]
      assert cached?(key), "the first request should have cached the row"

      assert {:ok, %Key{} = updated} =
               Keys.update_scopes(key, [read_scope(), write_scope()], scope)

      assert updated.scopes == [read_scope(), write_scope()]
      assert Repo.get!(Key, key.uuid).scopes == [read_scope(), write_scope()]
      refute cached?(key), "the edit must drop the cached row"

      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.scopes == [read_scope(), write_scope()]

      assert [entry] = entries("api.key_scopes_updated", key)
      assert entry.module == "api"
      assert entry.permanent
      assert entry.actor_uuid == holder.uuid
      assert entry.metadata["key_prefix"] == key.prefix
      assert entry.metadata["from"] == [read_scope()]
      assert entry.metadata["to"] == [read_scope(), write_scope()]
    end

    test "refuses a scope the key's owner cannot use, an unknown scope and a malformed list",
         ctx do
      # The owner of the key holds media only: write needs media.manage.
      {holder, _role, scope} = api_holder(["media"])
      {key, _} = create_key!(holder, scope, %{scopes: [read_scope()]})

      for bad <- [
            [write_scope()],
            [read_scope(), "ghost.things:read"],
            [123],
            read_scope(),
            nil
          ] do
        assert {:error, :invalid_scopes} = Keys.update_scopes(key, bad, scope), inspect(bad)
      end

      # An Owner as the editor does not widen the limit: it is the key owner's.
      assert {:error, :invalid_scopes} =
               Keys.update_scopes(key, [write_scope()], ctx.owner_scope)

      assert Repo.get!(Key, key.uuid).scopes == [read_scope()]
      assert entries("api.key_scopes_updated", key) == []
    end

    test "refuses a revoked key, also through a stale struct", ctx do
      {key, _} = create_key!(ctx.owner, ctx.owner_scope)
      {:ok, revoked} = Keys.revoke(key, ctx.owner.uuid)

      assert {:error, :revoked} = Keys.update_scopes(revoked, [read_scope()], ctx.owner_scope)
      # `key` still says revoked_at: nil; the row is re-read.
      assert {:error, :revoked} = Keys.update_scopes(key, [read_scope()], ctx.owner_scope)
      assert entries("api.key_scopes_updated", key) == []
    end

    test "a key that no longer exists is not found", ctx do
      {key, _} = create_key!(ctx.owner, ctx.owner_scope)
      Repo.delete!(key)

      assert {:error, :not_found} = Keys.update_scopes(key, [read_scope()], ctx.owner_scope)
    end

    test "the effective scopes of an edited key still follow the owner's permissions" do
      {holder, role, scope} = api_holder(["media", "media.manage"])
      {key, token} = create_key!(holder, scope, %{scopes: [read_scope(), write_scope()]})

      assert {:ok, updated} = Keys.update_scopes(key, [write_scope()], scope)
      assert Keys.effective_scopes(updated) == [write_scope()]
      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.scopes == [write_scope()]

      :ok = Permissions.revoke_permission(role.uuid, "media.manage")

      assert Keys.effective_scopes(updated) == []
      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.scopes == []
    end

    test "saving the list the key already has writes and logs nothing" do
      {holder, _role, scope} = api_holder(["media"])
      {key, token} = create_key!(holder, scope, %{scopes: [read_scope()]})
      assert {:ok, _} = Keys.verify(token, nil)

      assert {:ok, same} = Keys.update_scopes(key, [read_scope()], scope)
      assert same.scopes == [read_scope()]
      assert entries("api.key_scopes_updated", key) == []
      assert cached?(key), "an unchanged list must not drop the cache"
    end

    test "blank entries and duplicates are dropped" do
      {holder, _role, scope} = api_holder(["media", "media.manage"])
      {key, _} = create_key!(holder, scope, %{scopes: [read_scope()]})

      assert {:ok, updated} =
               Keys.update_scopes(
                 key,
                 [" " <> write_scope() <> " ", "", write_scope(), read_scope()],
                 scope
               )

      assert updated.scopes == [write_scope(), read_scope()]
    end
  end

  describe "can_manage?/2 and get_key/1" do
    test "can_manage?/2: Owner any key, creator their own, nobody else", ctx do
      {_a, _role, scope_a} = api_holder(["media"])
      {_b, _role, scope_b} = api_holder(["media"])
      {key, _} = create_key!(scope_a.user, scope_a)

      assert Keys.can_manage?(scope_a, key)
      assert Keys.can_manage?(ctx.owner_scope, key)
      refute Keys.can_manage?(scope_b, key)
      refute Keys.can_manage?(%Scope{}, key)
    end

    test "get_key/1 finds a key and answers nil for unknown or malformed uuids", ctx do
      {key, _} = create_key!(ctx.owner, ctx.owner_scope)

      assert %Key{uuid: uuid} = Keys.get_key(key.uuid)
      assert uuid == key.uuid
      assert Keys.get_key(UUIDv7.generate()) == nil
      assert Keys.get_key("not-a-uuid") == nil
      assert Keys.get_key(nil) == nil
    end
  end
end
