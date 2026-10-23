defmodule PhoenixKit.Migrations.Postgres.V223 do
  @moduledoc """
  V223: AI request costs in real nanodollars.

  `phoenix_kit_ai_requests.cost_cents` never held cents: `phoenix_kit_ai` stored a
  provider's reported cost as `round(dollars * 1_000_000)`, millionths of a dollar, while
  its documentation called them nanodollars. At that precision the cheap calls are lost:
  an embedding of a short query costs about $0.0000001, so its row said `0`, and a
  1,000-token embedding (about 20 units) was off by up to 2.5%. A 4-byte `integer` could
  not hold real nanodollars either: it tops out at $2.15 per request.

  What the migration does: it renames the column to **`cost_nanodollars`** and makes it
  **`bigint`**, multiplying every stored cost by 1,000 in the same rewrite, so the value
  is the same amount of money in billionths of a dollar. The rename is deliberate: a
  `phoenix_kit_ai` that still writes millionths fails on the missing column instead of
  storing costs 1,000 times too small.

  Only the journal changes unit. The spend caps (`ai_daily_budget*` in
  `phoenix_kit_settings`), the task limits and the prices per 1M tokens stay in
  micro-dollars; `phoenix_kit_ai` turns a sum of the journal into micro-dollars before it
  meets one of them, so no setting is touched here.

  The two spend indexes (V193) carry the column in `INCLUDE` and follow the rename.

  Running it again changes nothing: the rewrite happens only while a `cost_cents` column
  exists, so no cost is multiplied twice. A table holding both columns (repaired by hand,
  say) stops the migration with an error instead of being marked migrated with its old
  costs left in `cost_cents`.

  Needs the `phoenix_kit_ai` release that writes `cost_nanodollars`.

  ## Locks

  `ALTER COLUMN … TYPE bigint` rewrites the requests table and its indexes once, under
  an `ACCESS EXCLUSIVE` lock: AI calls wait to write their usage rows, and spend checks
  wait to read them, until it is done. Re-runnable.

  ## Down

  Divides the costs by 1,000 (rounding to the nearest millionth of a dollar — the
  precision V223 added is lost), makes the column `integer` again and renames it back to
  `cost_cents`. A single request that cost more than $2,147 cannot be stored as an
  `integer` and stops the rollback.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V223 back: costs divided by 1,000, the column back to `integer cost_cents`."
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
        IF #{column_exists(prefix, "cost_cents")}
          AND #{column_exists(prefix, "cost_nanodollars")} THEN
          RAISE EXCEPTION 'V223: #{t} has both cost_cents and cost_nanodollars; move the costs into one of them (cost_nanodollars = cost_cents * 1000) and drop the other, then migrate again';
        ELSIF #{column_exists(prefix, "cost_cents")} THEN
          ALTER TABLE #{t} RENAME COLUMN cost_cents TO cost_nanodollars;
          ALTER TABLE #{t} ALTER COLUMN cost_nanodollars TYPE bigint
            USING cost_nanodollars::bigint * 1000;
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
        IF #{column_exists(prefix, "cost_nanodollars")}
          AND #{column_exists(prefix, "cost_cents")} THEN
          RAISE EXCEPTION 'V223 down: #{t} has both cost_cents and cost_nanodollars; keep one of them, then roll back again';
        ELSIF #{column_exists(prefix, "cost_nanodollars")} THEN
          ALTER TABLE #{t} ALTER COLUMN cost_nanodollars TYPE integer
            USING round(cost_nanodollars / 1000.0)::integer;
          ALTER TABLE #{t} RENAME COLUMN cost_nanodollars TO cost_cents;
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
