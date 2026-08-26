defmodule PhoenixKit.Migrations.Postgres.V181 do
  @moduledoc """
  V181: `phoenix_kit_users.user_timezone` widens from `varchar(3)` to
  `varchar(64)`, so it can hold an IANA identifier.

  ## Why it was three characters

  The column was sized for the values it used to hold: `"+14"`, `"-12"`, `"0"`.
  A timezone was stored as an integer offset, and three characters is exactly
  enough for one.

  That storage decision is the root of the reported bugs. An offset cannot
  carry a location, so it cannot follow daylight saving: an account set from
  Helsinki in January stored `"2"` and read an hour behind all summer. The
  picker had to name cities by their winter offset, which put Johannesburg
  (UTC+2 every day) in the same row as Helsinki (UTC+2 only in winter).

  Storing `Europe/Helsinki` instead fixes all of it — and needs 15 characters.
  `varchar(64)` leaves room for the longest identifiers in the database
  (`America/Argentina/ComodRivadavia` is 32) and for whatever IANA adds.

  ## Existing rows are left exactly as they are

  Widening a `varchar` is metadata-only in PostgreSQL: no table rewrite, no
  lock beyond a brief `ACCESS EXCLUSIVE`, and every stored `"2"` stays `"2"`.

  They are deliberately NOT converted to identifiers. `"2"` is genuinely
  ambiguous — `Europe/Warsaw` in summer, `Africa/Johannesburg` in any season —
  and a migration that guessed would write a location onto an account whose
  owner never chose it. `PhoenixKit.Utils.TimeZone` keeps reading them as fixed
  offsets, so nobody's timestamps move, and the profile offers the real zone
  the browser reports.

  ## down/1

  Narrowing back to `varchar(3)` would fail on any row holding an identifier,
  so `down/1` first blanks those, leaving the numeric offsets untouched. That
  loses a preference rather than the migration, which is the better of the two
  outcomes available when the column can no longer represent the value.
  """

  use Ecto.Migration

  @column_length 64

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_users
      ALTER COLUMN user_timezone TYPE varchar(#{@column_length})
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '181'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Anything that will not fit in three characters cannot survive the
    # narrowing. Clearing it degrades to "use the system default" rather than
    # aborting the rollback.
    execute("""
    UPDATE #{p}phoenix_kit_users
       SET user_timezone = NULL
     WHERE user_timezone IS NOT NULL
       AND length(user_timezone) > 3
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_users
      ALTER COLUMN user_timezone TYPE varchar(3)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '180'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
