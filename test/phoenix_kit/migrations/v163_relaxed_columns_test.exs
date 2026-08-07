defmodule PhoenixKit.Migrations.V163RelaxedColumnsTest do
  @moduledoc """
  Self-maintenance guard for `PhoenixKit.Migrations.Postgres.V163`'s
  `@relaxed_after_v57` list (see that module's moduledoc section of the
  same name): V163 re-imposes NOT NULL on every
  `UUIDFKColumns.not_null_uuid_fks/0` column *except* the ones in that
  list. If some later version (after V57, where the flush-order bug this
  version repairs was fixed) drops NOT NULL again on a tracked column
  without updating the exclusion list, V163 would silently start
  re-breaking that relaxation on every fresh single-shot install — exactly
  the class of bug GLM's review of `b213332e` caught for
  `phoenix_kit_files.user_uuid`/V113.

  DB-free: statically scans migration SOURCE TEXT, never touches a
  database. Two extraction strategies, matching the two shapes this exact
  operation actually takes in this chain (verified 2026-08-04 by reading
  every real occurrence, not assumed):

    * inline literal — `ALTER TABLE <table> ALTER COLUMN <column> DROP NOT
      NULL` with both names written out directly (V113/V126/V127/V152's
      style);
    * table/column tuple lists feeding a loop — `{"table", "column"}`
      (V67/V69's style), where the actual `ALTER COLUMN` uses a loop
      variable the text alone can't resolve, so the DATA the loop iterates
      is scanned instead.

  Both extractions are deliberately OVER-inclusive (a tuple list is
  credited to a file the moment the file merely contains the string "DROP
  NOT NULL" *anywhere*, without proving that exact list feeds that exact
  statement) — false positives just mean an unrelated `{table, column}`
  pair gets cross-checked against `not_null_uuid_fks/0` and (almost
  certainly) found not to be a member, a no-op. A false NEGATIVE — a real
  relaxation this scan fails to see at all — is the failure mode that
  matters, so erring toward "flag it" is the correct default (this
  codebase's standing convention for exactly this kind of guard, e.g.
  `InventoryGuard`).
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.V163
  alias PhoenixKit.Migrations.UUIDFKColumns

  # V163 itself is exempt — its own moduledoc discusses "DROP NOT NULL" in
  # prose (documenting the very thing this test guards), which is not a
  # real relaxation to catch. Every version strictly after it is fair game
  # for a hypothetical future V164+ that relaxes a tracked column.
  @exempt_version 163

  # The flush-order bug V163 repairs was fixed in V56/V57 — a version at or
  # before V57 declaring `not_null_uuid_fks/0` in the first place is not a
  # "later" relaxation of it.
  @first_version_in_scope 58

  @inline_pattern ~r/
    ALTER\s+TABLE\s+\S*?(phoenix_kit_[a-zA-Z0-9_]+)
    \s+ALTER\s+COLUMN\s+([a-zA-Z_][a-zA-Z0-9_]*)
    \s+DROP\s+NOT\s+NULL
  /xi

  @tuple_pattern ~r/\{\s*"(phoenix_kit_[a-z0-9_]+)"\s*,\s*"([a-z0-9_]+)"\s*\}/i

  test "every not_null_uuid_fks/0 column dropped NOT NULL after V57 is in V163's exclusion list" do
    tracked = MapSet.new(UUIDFKColumns.not_null_uuid_fks())
    exclusion = MapSet.new(V163.relaxed_after_v57())

    # The exclusion list itself must only ever name tracked columns — a
    # stale/typo'd entry would silently defeat this whole guard.
    assert MapSet.subset?(exclusion, tracked),
           "V163.relaxed_after_v57/0 contains #{inspect(MapSet.difference(exclusion, tracked) |> MapSet.to_list())}, " <>
             "which #{if MapSet.size(exclusion) == 1, do: "is", else: "are"} not in " <>
             "UUIDFKColumns.not_null_uuid_fks/0 at all — fix or remove the stale entry"

    found =
      @first_version_in_scope..Postgres.current_version()
      |> Enum.reject(&(&1 == @exempt_version))
      |> Enum.flat_map(&candidates_for_version/1)
      |> MapSet.new()
      |> MapSet.intersection(tracked)

    missing = MapSet.difference(found, exclusion)

    assert MapSet.size(missing) == 0, """
    Found #{MapSet.size(missing)} tracked not_null_uuid_fks/0 column(s) that a version \
    after V57 drops NOT NULL on, but V163.relaxed_after_v57/0 does not list:

    #{missing |> MapSet.to_list() |> Enum.map_join("\n", fn {t, c} -> "  - #{t}.#{c}" end)}

    If this is a genuine, intentional relaxation (mirrors the phoenix_kit_files.user_uuid/V113 \
    case), read the migration to understand WHY, then add it to \
    lib/phoenix_kit/migrations/postgres/v163.ex's @relaxed_after_v57 with a provenance comment \
    (which version, why) and update V163's moduledoc "@relaxed_after_v57" section to match. If \
    this is a false positive (the extraction matched an unrelated {table, column} tuple that \
    doesn't actually back a DROP NOT NULL statement), narrow this test's extraction instead of \
    silently ignoring it.
    """
  end

  # `File.cwd!/0` is the project root under `mix test` (this repo's own
  # convention throughout `dev_docs/squash/*.exs`, which reference `lib/...`
  # the same way) — `Application.app_dir/2` would resolve into `_build/`,
  # where only compiled `.beam` output lands, never the `.ex` sources this
  # test needs to read.
  defp candidates_for_version(version) do
    path = Path.join(File.cwd!(), "lib/phoenix_kit/migrations/postgres/v#{version}.ex")

    if File.exists?(path) do
      text = File.read!(path)
      inline_candidates(text) ++ tuple_candidates(text)
    else
      []
    end
  end

  defp inline_candidates(text) do
    @inline_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_, table, column] -> {String.to_atom(table), column} end)
  end

  # Only scanned when the file mentions the operation at all — a tuple list
  # feeding some OTHER kind of loop (e.g. UUIDFKColumns' own FK-constraint
  # tuples, which are 5-element, never matches this 2-element pattern
  # anyway) in a file that never drops NOT NULL is not a candidate.
  defp tuple_candidates(text) do
    if String.contains?(text, "DROP NOT NULL") do
      @tuple_pattern
      |> Regex.scan(text)
      |> Enum.map(fn [_, table, column] -> {String.to_atom(table), column} end)
    else
      []
    end
  end
end
