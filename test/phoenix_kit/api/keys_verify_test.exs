defmodule PhoenixKit.API.KeysVerifyTest do
  @moduledoc """
  `PhoenixKit.API.Keys.verify/2`: every way a presented token can be refused,
  the owner checks, and the 60 second key row cache (a key whose owner was
  blocked, deleted or demoted stops working on the very next request even while
  its row is cached).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.Keys.Token
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  setup do
    register_fake_module!()
    start_key_cache!()
    :ok
  end

  # An api holder with `media` and `media.manage`, and a key for the two scopes.
  defp holder_with_key(attrs \\ %{}) do
    {user, role, scope} = api_holder(["media", "media.manage"])

    {key, token} =
      create_key!(user, scope, Map.merge(%{scopes: [read_scope(), write_scope()]}, attrs))

    %{user: user, role: role, scope: scope, key: key, token: token}
  end

  defp cached?(key), do: match?(%Key{}, PhoenixKit.Cache.get(:api_keys, key.prefix))

  defp past, do: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)

  # Writes the row without going through Keys, as another node or a console would.
  defp set_row(key, fields) do
    Repo.update_all(from(k in Key, where: k.uuid == ^key.uuid), set: fields)
  end

  describe "verify/2 with a good token" do
    test "returns an actor for the key, with the effective scopes" do
      %{key: key, user: user, token: token} = holder_with_key(%{requires_approval: true})

      assert {:ok, %Actor{} = actor} = Keys.verify(token, "203.0.113.9")

      assert actor.kind == :key
      assert actor.key_uuid == key.uuid
      assert actor.key_prefix == key.prefix
      assert actor.user_uuid == user.uuid
      assert actor.scopes == [read_scope(), write_scope()]
      assert actor.requires_approval
      assert actor.ip == "203.0.113.9"
    end

    test "an IP of nil is fine for a key without an allow-list" do
      %{token: token} = holder_with_key()
      assert {:ok, %Actor{ip: nil}} = Keys.verify(token, nil)
    end

    test "records last_used_at and last_used_ip, at most once a minute" do
      %{key: key, token: token} = holder_with_key()
      assert Repo.get!(Key, key.uuid).last_used_at == nil

      assert {:ok, _} = Keys.verify(token, "203.0.113.9")
      stored = Repo.get!(Key, key.uuid)
      assert %DateTime{} = stored.last_used_at
      assert stored.last_used_ip == "203.0.113.9"

      # A second request inside the minute must not write again.
      set_row(key, last_used_at: nil, last_used_ip: nil)
      assert {:ok, _} = Keys.verify(token, "203.0.113.10")
      assert Repo.get!(Key, key.uuid).last_used_at == nil
    end
  end

  describe "verify/2 refuses" do
    test "anything that is not a token, without raising" do
      for bad <- ["", "Bearer", "pk_", "pk_0123abcd_short", "not a token", nil, 42, %{}] do
        assert {:error, :invalid_token} = Keys.verify(bad, "203.0.113.9"), inspect(bad)
      end
    end

    test "a token with a known prefix and the wrong secret" do
      %{key: key} = holder_with_key()
      {_, other_token, _} = Token.generate()

      forged =
        "pk_" <> key.prefix <> "_" <> (other_token |> String.split("_", parts: 3) |> List.last())

      assert {:error, :invalid_token} = Keys.verify(forged, "203.0.113.9")
    end

    test "a well-formed token with an unknown prefix" do
      {_, token, _} = Token.generate()
      assert {:error, :invalid_token} = Keys.verify(token, "203.0.113.9")
    end

    test "a revoked key" do
      %{key: key, token: token} = holder_with_key()
      assert {:ok, _} = Keys.verify(token, nil)

      set_row(key, revoked_at: past())
      Cache.invalidate(key.prefix)

      assert {:error, :revoked} = Keys.verify(token, nil)
    end

    test "a key whose revocation is still in the future works until then" do
      %{key: key, token: token} = holder_with_key()

      set_row(key,
        revoked_at: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      )

      Cache.invalidate(key.prefix)

      assert {:ok, _} = Keys.verify(token, nil)

      set_row(key, revoked_at: past())
      Cache.invalidate(key.prefix)
      assert {:error, :revoked} = Keys.verify(token, nil)
    end

    test "an expired key" do
      %{key: key, token: token} =
        holder_with_key(%{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)})

      assert {:ok, _} = Keys.verify(token, nil)

      set_row(key,
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      )

      Cache.invalidate(key.prefix)

      assert {:error, :expired} = Keys.verify(token, nil)
    end

    test "an address outside the allow-list, and a missing address" do
      %{token: token} = holder_with_key(%{allowed_ips: ["203.0.113.0/24", "2001:db8::/32"]})

      assert {:ok, _} = Keys.verify(token, "203.0.113.200")
      assert {:ok, _} = Keys.verify(token, "2001:db8::7")
      assert {:error, :ip_not_allowed} = Keys.verify(token, "198.51.100.1")
      assert {:error, :ip_not_allowed} = Keys.verify(token, nil)
      assert {:error, :ip_not_allowed} = Keys.verify(token, "unknown")
    end

    test "a key whose owner is blocked" do
      %{token: token, user: user} = holder_with_key()
      assert {:ok, _} = Keys.verify(token, nil)

      {:ok, _} = Auth.update_user_status(user, %{is_active: false})
      assert {:error, :owner_inactive} = Keys.verify(token, nil)
    end
  end

  describe "clock edges, with and without the row cache" do
    # The column holds whole seconds, so a value written as "now" is always
    # earlier than the instant of the check. These two tests pin that a deadline
    # that has just passed refuses the key; they cannot reach the exact-equality
    # branch of the comparison.
    test "a key whose expires_at was truncated to the current second is expired" do
      %{key: key, token: token} = holder_with_key()
      assert {:ok, _} = Keys.verify(token, nil)

      # `expires_at` is a whole-second column, so "now" is the current second,
      # which is never later than the instant of the check.
      set_row(key, expires_at: DateTime.truncate(DateTime.utc_now(), :second))
      Cache.invalidate(key.prefix)

      assert {:error, :expired} = Keys.verify(token, nil)
    end

    test "a key whose revoked_at was truncated to the current second is revoked" do
      %{key: key, token: token} = holder_with_key()
      assert {:ok, _} = Keys.verify(token, nil)

      set_row(key, revoked_at: DateTime.truncate(DateTime.utc_now(), :second))
      Cache.invalidate(key.prefix)

      assert {:error, :revoked} = Keys.verify(token, nil)
    end

    test "a cached key whose expires_at passes inside the TTL is refused without an invalidation" do
      %{key: key, token: token} =
        holder_with_key(%{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)})

      assert {:ok, _} = Keys.verify(token, nil)
      assert %Key{} = cached = PhoenixKit.Cache.get(:api_keys, key.prefix)

      # The cache holds the row as loaded while the key was live. Time passing
      # is simulated by moving the CACHED copy's expiry into the past, with the
      # database row untouched: if verify/2 re-read the database it would answer
      # {:ok, _}, so the refusal can only come from the clock check on the
      # cached row.
      :ok = PhoenixKit.Cache.put(:api_keys, key.prefix, %{cached | expires_at: past()})

      assert {:error, :expired} = Keys.verify(token, nil)
      assert Repo.get!(Key, key.uuid).expires_at != nil
      assert DateTime.compare(Repo.get!(Key, key.uuid).expires_at, DateTime.utc_now()) == :gt
      assert cached?(key), "nothing invalidated the cache"
    end

    test "a cached key whose scheduled revoked_at passes inside the TTL is refused without an invalidation" do
      %{key: key, token: token} = holder_with_key()

      # A rotation grace period: revoked_at is in the future when the row is cached.
      set_row(key,
        revoked_at: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      )

      Cache.invalidate(key.prefix)
      # The listener handles the node's own broadcast asynchronously; wait for it,
      # or it can drop the row that the next verify/2 loads.
      _ = :sys.get_state(Cache)
      assert {:ok, _} = Keys.verify(token, nil)
      assert %Key{} = cached = PhoenixKit.Cache.get(:api_keys, key.prefix)

      :ok = PhoenixKit.Cache.put(:api_keys, key.prefix, %{cached | revoked_at: past()})

      assert {:error, :revoked} = Keys.verify(token, nil)
      assert DateTime.compare(Repo.get!(Key, key.uuid).revoked_at, DateTime.utc_now()) == :gt
      assert cached?(key), "nothing invalidated the cache"
    end
  end

  describe "the owner changes while the key row is cached" do
    test "unconfirming a human owner stops cached keys and queued actors" do
      %{token: token, key: key, user: user} = holder_with_key()
      confirmed_at = DateTime.truncate(DateTime.utc_now(), :second)

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid),
        set: [confirmed_at: confirmed_at]
      )

      assert {:ok, _} = Keys.verify(token, nil)
      assert cached?(key)

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid),
        set: [confirmed_at: nil]
      )

      assert {:error, :owner_inactive} = Keys.verify(token, nil)
      assert {:error, :owner_inactive} = Confirm.live_actor(key.uuid)
      refute Keys.active?(key)
      assert cached?(key)

      put_setting("require_email_confirmation", "false")
      assert {:ok, _} = Keys.verify(token, nil)
      assert {:ok, _} = Confirm.live_actor(key.uuid)
    end

    test "service users do not need email confirmation" do
      {role, _} = role_with(["media"])
      service = service_user_with([role.name])
      {key, token} = create_key!(service, scope_of(owner_user()))

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^service.uuid),
        set: [confirmed_at: nil]
      )

      assert {:ok, _} = Keys.verify(token, nil)
      assert {:ok, _} = Confirm.live_actor(key.uuid)
      assert Keys.active?(key)
    end

    test "demoting the owner narrows the key on the very next request" do
      %{token: token, key: key, user: user, role: role} = holder_with_key()

      assert {:ok, %Actor{scopes: [_, _]}} = Keys.verify(token, nil)
      assert cached?(key), "the first request should have cached the key row"

      :ok = Permissions.revoke_permission(role.uuid, "media.manage")

      assert {:ok, %Actor{scopes: scopes}} = Keys.verify(token, nil)
      assert scopes == [read_scope()]
      assert cached?(key), "the row must still come from the cache"

      {:ok, _} = Roles.remove_role(user, role.name)

      assert {:ok, %Actor{scopes: []}} = Keys.verify(token, nil)
      assert cached?(key)
    end

    test "blocking the owner stops the key on the very next request" do
      %{token: token, key: key, user: user} = holder_with_key()

      assert {:ok, _} = Keys.verify(token, nil)
      assert cached?(key)

      {:ok, blocked} = Auth.update_user_status(user, %{is_active: false})

      assert {:error, :owner_inactive} = Keys.verify(token, nil)
      assert cached?(key)

      {:ok, _} = Auth.update_user_status(blocked, %{is_active: true})
      assert {:ok, %Actor{}} = Keys.verify(token, nil)
    end

    test "deleting the owner stops the key on the very next request" do
      %{token: token, key: key, user: user} = holder_with_key()

      assert {:ok, _} = Keys.verify(token, nil)
      assert cached?(key)

      assert {:ok, _} = Auth.delete_user(user, %{current_user: owner_user()})

      assert {:error, :owner_inactive} = Keys.verify(token, nil)
      assert cached?(key)
    end

    test "the key row itself is served from the cache until it is invalidated" do
      %{token: token, key: key} = holder_with_key()
      assert {:ok, _} = Keys.verify(token, nil)

      # Revoked behind the cache's back: the cached row still says "live".
      set_row(key,
        revoked_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      assert {:ok, _} = Keys.verify(token, nil)

      # Invalidation (what revoke/2 and rotate/3 do) makes the change visible.
      Cache.invalidate(key.prefix)
      assert {:error, :revoked} = Keys.verify(token, nil)
    end
  end
end
