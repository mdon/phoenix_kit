defmodule PhoenixKit.API.KeysTest do
  @moduledoc """
  `PhoenixKit.API.Keys` against the real database, role permissions and module
  registry. A stand-in module (`PhoenixKit.API.KeyTestSupport.FakeModule`)
  declares the tools whose scopes the keys carry.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.Keys.Token
  alias PhoenixKit.Users.Auth

  setup do
    register_fake_module!()
    start_key_cache!()

    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  defp entries(action, key) do
    Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^key.uuid))
  end

  describe "create_key/3" do
    test "an Owner creates a key for themselves and gets the token once", ctx do
      attrs = %{
        name: "Accounting",
        scopes: [read_scope(), write_scope()],
        requires_approval: true
      }

      assert {:ok, %Key{} = key, token} = Keys.create_key(ctx.owner, ctx.owner_scope, attrs)

      assert token =~ ~r/\Apk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}\z/
      assert key.prefix == Token.prefix(token)
      assert key.user_uuid == ctx.owner.uuid
      assert key.created_by_uuid == ctx.owner.uuid
      assert key.name == "Accounting"
      assert key.scopes == [read_scope(), write_scope()]
      assert key.requires_approval
      assert key.allowed_ips == []
      assert key.revoked_at == nil

      stored = Repo.get!(Key, key.uuid)

      secret =
        token |> String.split("_", parts: 3) |> List.last() |> Base.url_decode64!(padding: false)

      assert byte_size(secret) == 32
      assert stored.secret_hash == :crypto.hash(:sha256, secret)
    end

    test "writes a permanent api.key_created entry that never holds the token", ctx do
      {key, token} = create_key!(ctx.owner, ctx.owner_scope, %{allowed_ips: ["203.0.113.0/24"]})

      assert [entry] = entries("api.key_created", key)
      assert entry.module == "api"
      assert entry.permanent
      assert entry.actor_uuid == ctx.owner.uuid
      assert entry.resource_type == "api_key"
      assert entry.metadata["key_prefix"] == key.prefix
      assert entry.metadata["owner_uuid"] == ctx.owner.uuid
      assert entry.metadata["scopes"] == [read_scope()]
      assert entry.metadata["allowed_ips"] == ["203.0.113.0/24"]

      secret = token |> String.split("_", parts: 3) |> List.last()
      refute inspect(entry.metadata) =~ secret
    end

    test "accepts string keys, as a form sends them", ctx do
      assert {:ok, key, _token} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 "name" => "From a form",
                 "scopes" => [read_scope()],
                 "allowed_ips" => ["203.0.113.7"]
               })

      assert key.allowed_ips == ["203.0.113.7/32"]
    end

    test "refuses a creator who does not hold api, and stores nothing" do
      {user, _role} = user_without_api(["media"])
      before = Repo.aggregate(Key, :count)

      assert {:error, :forbidden} =
               Keys.create_key(user, scope_of(user), %{name: "x", scopes: [read_scope()]})

      assert Repo.aggregate(Key, :count) == before
    end

    test "a creator without a user is refused" do
      assert {:error, :forbidden} =
               Keys.create_key(owner_user(), %PhoenixKit.Users.Auth.Scope{}, %{name: "x"})
    end

    test "an api holder can own a key themselves" do
      {user, _role, scope} = api_holder(["media"])
      assert {:ok, key, _} = Keys.create_key(user, scope, %{name: "Mine", scopes: [read_scope()]})
      assert key.user_uuid == user.uuid
      assert key.created_by_uuid == user.uuid
    end

    test "refuses a scope the owner's permissions do not cover" do
      # Holds api and media, but not media.manage, which write needs.
      {user, _role, scope} = api_holder(["media"])

      assert {:error, :invalid_scopes} =
               Keys.create_key(user, scope, %{
                 name: "Too much",
                 scopes: [read_scope(), write_scope()]
               })
    end

    test "refuses a scope no enabled tool declares, even for an Owner", ctx do
      assert {:error, :invalid_scopes} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "Ghost",
                 scopes: ["ghost.things:read"]
               })
    end

    test "a non-Owner cannot give a key to another regular user, nor to an Owner" do
      {creator, _role, scope} = api_holder(["media"])
      other = register_user!()

      assert {:error, :owner_not_allowed} =
               Keys.create_key(other, scope, %{name: "x", scopes: [read_scope()]})

      assert {:error, :owner_not_allowed} =
               Keys.create_key(owner_user(), scope, %{name: "x", scopes: [read_scope()]})

      assert creator.uuid != other.uuid
    end

    test "a service user whose roles are within the creator's rights can own a key" do
      {_creator, _role, scope} = api_holder(["media", "media.manage"])
      {service_role, _} = role_with(["media"])
      service = service_user_with([service_role.name])

      assert {:ok, key, _} =
               Keys.create_key(service, scope, %{name: "Robot", scopes: [read_scope()]})

      assert key.user_uuid == service.uuid
      assert key.created_by_uuid == scope.user.uuid
    end

    test "a service user with a role beyond the creator's rights is refused" do
      {_creator, _role, scope} = api_holder(["media"])
      {big_role, _} = role_with(["media", "media.manage"])
      service = service_user_with([big_role.name])

      assert {:error, :owner_not_allowed} =
               Keys.create_key(service, scope, %{name: "Robot", scopes: [read_scope()]})
    end

    test "an Owner can give a key to any service user" do
      owner = owner_user()
      {big_role, _} = role_with(["media", "media.manage", "jobs", "jobs.manage"])
      service = service_user_with([big_role.name])

      assert {:ok, key, _} =
               Keys.create_key(service, scope_of(owner), %{
                 name: "Robot",
                 scopes: all_scopes()
               })

      assert Enum.sort(key.scopes) == Enum.sort(all_scopes())
    end

    test "the caller's claim that a user is a service user is not believed" do
      {_creator, _role, scope} = api_holder(["media"])
      regular = register_user!()

      assert {:error, :owner_not_allowed} =
               Keys.create_key(%{regular | api_only: true}, scope, %{name: "Forged", scopes: []})
    end

    test "a scope is checked against the service user's permissions, not the creator's" do
      {_creator, _role, scope} = api_holder(["media", "media.manage"])
      {service_role, _} = role_with(["media"])
      service = service_user_with([service_role.name])

      assert {:error, :invalid_scopes} =
               Keys.create_key(service, scope, %{name: "Robot", scopes: [write_scope()]})
    end

    test "refuses an inactive owner", ctx do
      {:ok, blocked} = Auth.update_user_status(register_user!(), %{is_active: false})
      {_creator, _role, scope} = api_holder()

      assert {:error, :owner_inactive} = Keys.create_key(blocked, scope, %{name: "x"})
      assert ctx.owner.is_active
    end

    test "returns a changeset for invalid attributes", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{name: "  "})

      assert %{name: [_ | _]} = errors_on(cs)

      assert {:error, cs} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{name: String.duplicate("n", 101)})

      assert %{name: [_ | _]} = errors_on(cs)

      assert {:error, cs} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "Bad ips",
                 allowed_ips: ["203.0.113.0/24", "not-an-ip", "10.0.0.0/33"]
               })

      assert [message] = errors_on(cs).allowed_ips
      assert message =~ "not-an-ip"
      assert message =~ "10.0.0.0/33"

      assert {:error, cs} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "Old",
                 expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
               })

      assert %{expires_at: ["must be in the future"]} = errors_on(cs)
    end

    test "an explicit nil for scopes, allowed_ips or requires_approval means the default", ctx do
      for attrs <- [
            %{name: "Nil scopes", scopes: nil},
            %{name: "Nil ips", allowed_ips: nil},
            %{name: "Nil approval", requires_approval: nil},
            %{
              "name" => "Nil form",
              "scopes" => nil,
              "allowed_ips" => nil,
              "requires_approval" => nil
            }
          ] do
        assert {:ok, key, _token} = Keys.create_key(ctx.owner, ctx.owner_scope, attrs),
               inspect(attrs)

        assert key.scopes == []
        assert key.allowed_ips == []
        refute key.requires_approval
      end
    end

    test "an allow-list holds at most 100 entries", ctx do
      entries = for i <- 1..101, do: "203.0.113.#{i}"

      assert {:ok, key, _} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "Hundred",
                 allowed_ips: Enum.take(entries, 100)
               })

      assert length(key.allowed_ips) == 100

      assert {:error, %Ecto.Changeset{} = cs} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "Too many",
                 allowed_ips: entries
               })

      assert %{allowed_ips: [_ | _]} = errors_on(cs)
    end

    test "scopes are trimmed and de-duplicated; a future expiry is kept", ctx do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      {key, _token} =
        create_key!(ctx.owner, ctx.owner_scope, %{
          scopes: [" " <> read_scope(), read_scope(), ""],
          expires_at: expires_at
        })

      assert key.scopes == [read_scope()]
      assert DateTime.compare(key.expires_at, expires_at) == :eq
    end
  end
end
