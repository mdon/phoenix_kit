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

  De-duplication keeps the EARLIEST row of each duplicate set. All three
  tables have a UUIDv7 primary key, which is time-ordered, so the smallest
  `uuid` in a set is the first one written — `a.uuid > b.uuid` removes the
  later arrival and keeps the relationship the user established first.
  Nothing is lost that the pair still needs: a follow, block or connection
  between the same two users still exists afterwards, with its original
  timestamp. The module's `*_history` tables are untouched and keep the full
  record either way.

  The connection index is on `(requester_uuid, recipient_uuid)` because that
  is the pair the schema names. It deliberately does NOT normalise the pair:
  A→B and B→A remain two insertable rows, which is the existing behaviour
  `request_connection/2` relies on when it auto-accepts a mutual pending
  request. Making the pair order-independent would change module behaviour
  rather than enforce what the module already claims.

  Rolling back drops the three indexes. It cannot bring back removed
  duplicates, which is correct: they were never valid.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    dedupe(p, "phoenix_kit_user_follows", "follower_uuid", "followed_uuid")
    dedupe(p, "phoenix_kit_user_blocks", "blocker_uuid", "blocked_uuid")
    dedupe(p, "phoenix_kit_user_connections", "requester_uuid", "recipient_uuid")

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
      ON #{p}phoenix_kit_user_connections USING btree (requester_uuid, recipient_uuid)
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

  # Keeps the smallest uuid per pair. UUIDv7 is time-ordered, so that is the
  # row written first. Runs before the index so CREATE UNIQUE INDEX cannot
  # fail on an install that already raced one in.
  defp dedupe(p, table, left, right) do
    execute("""
    DELETE FROM #{p}#{table} a
    USING #{p}#{table} b
    WHERE a.#{left} = b.#{left}
      AND a.#{right} = b.#{right}
      AND a.uuid > b.uuid
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
