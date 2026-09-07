defmodule PhoenixKit.Migrations.Postgres.V187 do
  @moduledoc """
  V187: `phoenix_kit_access_attempts` — every try at the website password
  gate.

  ## Why

  The gate (Website access settings) is a hard block: a blank page with a
  password prompt before anyone sees anything. The agency wants to know
  what happens at that door — whether a bot is brute-forcing it, or the
  client who swears the password "doesn't work" is mistyping it or has caps
  lock on. So each attempt is kept with a `verdict` — `correct`, `case`
  (right letters, wrong case), `close` (a few characters off), `unrelated`,
  `empty` — where from, with what browser, and when. What was typed is kept
  as the "keep what was typed" setting says: everything (the default — the
  agency wants to see exactly what was typed), only a `case`/`close` near
  miss, or nothing. The lockout counts failures per address from here too.

  ## What it does

  One table, no foreign keys, an index on `(address, inserted_at)` for the
  lockout count. Rolling back drops it.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    Helpers.ensure_uuid_v7_function(prefix)
    uuid_default = Helpers.uuid_v7_call(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_access_attempts (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      verdict CHARACTER VARYING(16) NOT NULL,
      typed TEXT,
      address CHARACTER VARYING(64),
      user_agent TEXT,
      inserted_at TIMESTAMP WITHOUT TIME ZONE NOT NULL
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_access_attempts_address_inserted_at_index
      ON #{p}phoenix_kit_access_attempts USING btree (address, inserted_at)
    """)

    # Single-step runs rely on the migration stamping its own marker — the
    # runner only writes it for multi-step ranges.
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '187'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_access_attempts")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '186'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
