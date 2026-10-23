defmodule PhoenixKit.Migrations.Postgres.V223 do
  @moduledoc """
  V223: an AI request's cost in dollars.

  `phoenix_kit_ai_requests.cost_cents` never held cents: `phoenix_kit_ai` stored a
  provider's reported cost as `round(dollars * 1_000_000)`, millionths of a dollar, so a
  cheap call (a short embedding costs about $0.0000001) was stored as `0`, and every
  reader had to divide.

  The column becomes **`cost`**, a **`numeric(20,10)`** amount of US dollars, like every
  other amount of money in the kit (`price`, `total`, `amount`): `0.00003` is three
  thousandths of a cent, and ten decimal places keep a call of $0.0000000001. The stored
  costs are converted in the same rewrite (`cost_cents / 1_000_000`). The rename is
  deliberate: a `phoenix_kit_ai` that still writes millionths fails on the missing column
  instead of storing costs a million times too large.

  A database that ran an unreleased V223 holding `cost_nanodollars` (billionths, `bigint`)
  is converted the same way (`/ 1_000_000_000`).

  The spend caps and other AI settings are not touched here; `phoenix_kit_ai`'s own
  migration chain converts them. The two spend indexes (V193) carry the column in
  `INCLUDE` and follow the rename.

  Running it again changes nothing: the rewrite happens only while a legacy column exists
  and `cost` does not. A table holding `cost` and a legacy column (repaired by hand, say)
  stops the migration with an error instead of being marked migrated with costs left
  behind.

  Needs the `phoenix_kit_ai` release that writes `cost`.

  ## Locks

  `ALTER COLUMN … TYPE` rewrites the requests table and its indexes once, under an
  `ACCESS EXCLUSIVE` lock: AI calls wait to write their usage rows, and spend checks wait
  to read them, until it is done. Re-runnable.

  ## Down

  Multiplies the costs back to millionths of a dollar (rounded — the precision V223 added
  is lost), makes the column `integer` again and renames it to `cost_cents`. A single
  request that cost more than $2,147.48 cannot be stored as an `integer` and stops the
  rollback.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V223 back: costs in millionths of a dollar again, in `integer cost_cents`."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    t = "#{p}phoenix_kit_ai_requests"

    [
      """
      DO $$
      BEGIN
        IF #{column_exists(prefix, "cost")}
          AND (#{column_exists(prefix, "cost_cents")}
               OR #{column_exists(prefix, "cost_nanodollars")}) THEN
          RAISE EXCEPTION 'V223: #{t} has cost and a legacy cost column (cost_cents or cost_nanodollars); move the costs into cost (dollars: cost_cents / 1000000, cost_nanodollars / 1000000000) and drop the legacy column, then migrate again';
        ELSIF #{column_exists(prefix, "cost_cents")}
          AND #{column_exists(prefix, "cost_nanodollars")} THEN
          RAISE EXCEPTION 'V223: #{t} has both cost_cents and cost_nanodollars; keep one of them, then migrate again';
        ELSIF #{column_exists(prefix, "cost_cents")} THEN
          ALTER TABLE #{t} ALTER COLUMN cost_cents TYPE numeric(20,10)
            USING cost_cents::numeric / 1000000;
          ALTER TABLE #{t} RENAME COLUMN cost_cents TO cost;
        ELSIF #{column_exists(prefix, "cost_nanodollars")} THEN
          ALTER TABLE #{t} ALTER COLUMN cost_nanodollars TYPE numeric(20,10)
            USING cost_nanodollars::numeric / 1000000000;
          ALTER TABLE #{t} RENAME COLUMN cost_nanodollars TO cost;
        END IF;
      END
      $$
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '223'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)
    t = "#{p}phoenix_kit_ai_requests"

    [
      """
      DO $$
      BEGIN
        IF #{column_exists(prefix, "cost")}
          AND #{column_exists(prefix, "cost_cents")} THEN
          RAISE EXCEPTION 'V223 down: #{t} has both cost and cost_cents; keep one of them, then roll back again';
        ELSIF #{column_exists(prefix, "cost")} THEN
          ALTER TABLE #{t} ALTER COLUMN cost TYPE integer
            USING round(cost * 1000000)::integer;
          ALTER TABLE #{t} RENAME COLUMN cost TO cost_cents;
        END IF;
      END
      $$
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '222'"
    ]
  end

  defp column_exists(prefix, column) do
    """
    EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = '#{prefix}'
            AND table_name = 'phoenix_kit_ai_requests'
            AND column_name = '#{column}'
        )\
    """
  end
end
