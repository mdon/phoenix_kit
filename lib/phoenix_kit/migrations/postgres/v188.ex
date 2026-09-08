defmodule PhoenixKit.Migrations.Postgres.V188 do
  @moduledoc """
  V188: the three uniqueness guarantees `phoenix_kit_user_connections`
  already believed it had.

  ## Why

  The module's schemas each declare a `unique_constraint/3` naming an index
  — `phoenix_kit_user_follows_unique_idx`,
  `phoenix_kit_user_blocks_unique_idx`,
  `phoenix_kit_user_connections_requester_recipient_uidx` — and none of the
  three has ever existed. `unique_constraint/3` only translates a database
  violation into a changeset error; with no index there is no violation, so
  the constraints were inert and the only guard was the module's
  read-then-write pre-check. Two concurrent follows, blocks or requests both
  pass that check and both insert, leaving a duplicate relationship no code
  path can produce deliberately and which every count then double-reports.

  ## What it does

  Removes existing duplicates, then creates the three unique indexes under
  exactly the names the schemas name, so those `unique_constraint/3` calls
  start working with no change to the module.

  ## Directed vs undirected, and why they differ

  Follows and blocks are DIRECTED. "A follows B" and "B follows A" are two
  different relationships, so their indexes are on the ordered pair and only
  an exact repeat of one direction is a duplicate.

  Connections are UNDIRECTED — one row represents one relationship, stored in
  whichever direction it was asked — so the index is on the unordered pair:

      (LEAST(requester_uuid, recipient_uuid),
       GREATEST(requester_uuid, recipient_uuid))

  An ordered index here would leave the race that actually matters open. Two
  users clicking "connect" on each other at the same moment both pass
  `request_connection/2`'s pre-check (`connected?/2` finds no accepted row,
  and each direction-specific pending lookup finds nothing) and both insert —
  one A→B row and one B→A row, which an ordered index permits. The damage is
  not cosmetic: the next request auto-accepts ONE of them and leaves the other
  as a live pending request between two already-connected users;
  `remove_connection/2` then deletes only the accepted row and leaves that
  ghost behind; and `get_accepted_connection/2` uses `Repo.one/1`, so a pair
  that ends up accepted twice raises `Ecto.MultipleResultsError`.

  The expression index is still reported under its own name in a `23505`, so
  the schema's existing `unique_constraint/3` keeps working unchanged — the
  field list only decides where the error is attached.

  Nothing legitimately needs both directions at once: a mutual request UPDATES
  the existing row to "accepted" rather than inserting a reverse one, and a
  removed connection deletes its row, freeing the pair for a later request.

  ## De-duplication

  Existing duplicates are removed first, or `CREATE UNIQUE INDEX` would fail.
  For follows and blocks the surviving row is the smallest `uuid`, which under
  UUIDv7's time ordering is the one written first. Connections rank
  "accepted" above "pending" before falling back to that rule, because the two
  can only coexist through the race being closed and the accepted row is the
  live relationship — dropping it for an older pending request would
  disconnect two connected users. The `*_history` tables are untouched and
  keep the full record either way.

  Rolling back drops the three indexes. It cannot bring back removed
  duplicates, which is correct: they were never valid.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    dedupe_directed(p, "phoenix_kit_user_follows", "follower_uuid", "followed_uuid")
    dedupe_directed(p, "phoenix_kit_user_blocks", "blocker_uuid", "blocked_uuid")
    dedupe_connection_pairs(p)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_user_follows_unique_idx
      ON #{p}phoenix_kit_user_follows USING btree (follower_uuid, followed_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_user_blocks_unique_idx
      ON #{p}phoenix_kit_user_blocks USING btree (blocker_uuid, blocked_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_user_connections_requester_recipient_uidx
      ON #{p}phoenix_kit_user_connections
      USING btree (LEAST(requester_uuid, recipient_uuid), GREATEST(requester_uuid, recipient_uuid))
    """)

    # Single-step runs rely on the migration stamping its own marker — the
    # runner only writes it for multi-step ranges.
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '188'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_user_follows_unique_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_user_blocks_unique_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_user_connections_requester_recipient_uidx")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '187'")
  end

  # Follows and blocks are DIRECTED: "A follows B" and "B follows A" are two
  # different relationships and both must survive. Only an exact repeat of the
  # same direction is a duplicate. Keeps the smallest uuid, which under UUIDv7's
  # time ordering is the row written first.
  defp dedupe_directed(p, table, left, right) do
    execute("""
    DELETE FROM #{p}#{table} a
    USING #{p}#{table} b
    WHERE a.#{left} = b.#{left}
      AND a.#{right} = b.#{right}
      AND a.uuid > b.uuid
    """)
  end

  # Connections are UNDIRECTED, so the duplicate set is the unordered pair and
  # a cross-direction pair (A->B and B->A) is just as much a duplicate as a
  # repeat of one direction. Both must go before the index can be built.
  #
  # Which row survives is not arbitrary:
  #
  #   * an "accepted" row outranks a "pending" one. The two can coexist only
  #     because of the race this migration closes, and the accepted row is the
  #     live relationship — deleting it in favour of an older pending request
  #     would disconnect two connected users.
  #   * within one rank the smallest uuid wins, which under UUIDv7 is the row
  #     written first, so "who asked" is preserved.
  #
  # Only "pending" and "accepted" ever persist ("rejected" and "cancelled"
  # delete the row), so those two ranks cover every stored row.
  defp dedupe_connection_pairs(p) do
    table = "#{p}phoenix_kit_user_connections"

    execute("""
    DELETE FROM #{table} a
    USING #{table} b
    WHERE LEAST(a.requester_uuid, a.recipient_uuid) = LEAST(b.requester_uuid, b.recipient_uuid)
      AND GREATEST(a.requester_uuid, a.recipient_uuid) = GREATEST(b.requester_uuid, b.recipient_uuid)
      AND a.uuid <> b.uuid
      AND ( (b.status = 'accepted')::int > (a.status = 'accepted')::int
            OR ( (b.status = 'accepted')::int = (a.status = 'accepted')::int
                 AND b.uuid < a.uuid ) )
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
