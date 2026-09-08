defmodule PhoenixKit.Migrations.UserConnectionsUniquenessTest do
  @moduledoc """
  V188's three unique indexes, checked by behaviour rather than by catalog.

  `phoenix_kit_user_connections`' schemas have always declared a
  `unique_constraint/3` naming each of these indexes, and until V188 none of
  them existed. `unique_constraint/3` only turns a DATABASE violation into a
  changeset error, so with no index there was no violation and the constraints
  were inert — the module's read-then-write pre-check was the only guard, and
  two concurrent writes sailed through it.

  `HandDeclaredManifestTest` already proves the manifest agrees with the chain
  for V171+, which covers these three objects structurally. What it cannot
  show is that they ENFORCE anything, or that the pair order is the one the
  module needs. That is what this file pins, because both are the properties a
  future migration could quietly break while leaving the catalog shape intact.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp user!(tag) do
    uuid = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO phoenix_kit_users (uuid, email, hashed_password, is_active, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2, 'x', true, now(), now())
      """,
      [uuid, "uniq-#{tag}-#{System.unique_integer([:positive])}@example.com"]
    )

    uuid
  end

  defp insert_follow(a, b) do
    Repo.query(
      """
      INSERT INTO phoenix_kit_user_follows (uuid, follower_uuid, followed_uuid, inserted_at)
      VALUES (uuid_generate_v7(), $1::text::uuid, $2::text::uuid, now())
      """,
      [a, b]
    )
  end

  defp insert_block(a, b) do
    Repo.query(
      """
      INSERT INTO phoenix_kit_user_blocks (uuid, blocker_uuid, blocked_uuid, inserted_at)
      VALUES (uuid_generate_v7(), $1::text::uuid, $2::text::uuid, now())
      """,
      [a, b]
    )
  end

  defp insert_connection(a, b) do
    Repo.query(
      """
      INSERT INTO phoenix_kit_user_connections
        (uuid, requester_uuid, recipient_uuid, status, requested_at, inserted_at, updated_at)
      VALUES (uuid_generate_v7(), $1::text::uuid, $2::text::uuid, 'pending', now(), now(), now())
      """,
      [a, b]
    )
  end

  describe "V188 unique indexes" do
    test "a duplicate follow is refused by the index the schema names" do
      a = user!("f1")
      b = user!("f2")

      assert {:ok, _} = insert_follow(a, b)

      assert {:error, %Postgrex.Error{postgres: pg}} = insert_follow(a, b)
      assert pg.code == :unique_violation
      assert pg.constraint == "phoenix_kit_user_follows_unique_idx"
    end

    test "a duplicate block is refused by the index the schema names" do
      a = user!("b1")
      b = user!("b2")

      assert {:ok, _} = insert_block(a, b)

      assert {:error, %Postgrex.Error{postgres: pg}} = insert_block(a, b)
      assert pg.code == :unique_violation
      assert pg.constraint == "phoenix_kit_user_blocks_unique_idx"
    end

    # Connections are UNDIRECTED: one row is one relationship, stored in
    # whichever direction it was asked. So BOTH a same-direction repeat and a
    # cross-direction row are duplicates, and the index is on the unordered
    # pair.
    test "a duplicate connection request is refused in either direction" do
      a = user!("c1")
      b = user!("c2")

      assert {:ok, _} = insert_connection(a, b)

      assert {:error, %Postgrex.Error{postgres: pg}} = insert_connection(a, b)
      assert pg.code == :unique_violation
      assert pg.constraint == "phoenix_kit_user_connections_requester_recipient_uidx"

      # The one that matters, and the one an ordered index would have let
      # through: two users clicking "connect" on each other at the same moment.
      # Both pass request_connection/2's pre-check, and without this the pair
      # ends up with two rows — one of which survives a later auto-accept as a
      # live pending request between two already-connected users, while
      # get_accepted_connection/2's Repo.one/1 raises if both become accepted.
      assert {:error, %Postgrex.Error{postgres: reverse}} = insert_connection(b, a)
      assert reverse.code == :unique_violation
      assert reverse.constraint == "phoenix_kit_user_connections_requester_recipient_uidx"
    end

    # The contrast that keeps the two shapes honest: follows and blocks are
    # DIRECTED, so their reverse is a different relationship and must stay
    # insertable. A future migration that "tidied" all three onto one shape
    # would break this.
    test "the directed relationships keep both directions" do
      a = user!("d1")
      b = user!("d2")

      assert {:ok, _} = insert_follow(a, b)
      assert {:ok, _} = insert_follow(b, a)

      assert {:ok, _} = insert_block(a, b)
      assert {:ok, _} = insert_block(b, a)
    end
  end
end
