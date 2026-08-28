defmodule PhoenixKit.Migrations.HandDeclaredManifestTest do
  @moduledoc """
  The PRODUCTION manifest, checked against a database the real chain built.

  Nothing else pins this. `repair_test.exs` exercises the repair machinery
  against a FIXTURE manifest, and `verify.exs --scenario s7,s8` needs a
  generated manifest from a pre-squash checkout, which is why the manifest's
  own header says the post-generation objects "have never been checked against
  a real database".

  Every version from V178 on was declared BY HAND (see the DECLARED
  POST-GENERATION blocks in `expected_schema.ex`), and a wrong `pos`, type,
  predicate or constraint name there makes `mix phoenix_kit.repair` try to
  "fix" a perfectly healthy install. This closes that gap for exactly those
  versions.

  ## Why it is scoped rather than asserting a clean report

  A full clean assertion fails today on two PRE-EXISTING findings that have
  nothing to do with the hand-declared block, recorded here so the next person
  does not rediscover them:

    * `index:phoenix_kit_notifications_dedupe_unseen_idx` and
      `..._recipient_unseen_first_idx` (both `since: 170`) declare expression
      keys with doubled parentheses — `"((metadata ->> 'dedupe_key'::text))"` —
      where the catalog reports single. A manifest-text bug, not a schema one.

  Widen `@hand_declared_from` down to 170 once those are fixed too.

  (Previously this list also carried `index:phoenix_kit_shop_category_slugs_pkey`
  and `..._shop_product_slugs_pkey`, since: 171: both are PRIMARY KEY on a
  composite natural key, so their backing index is excluded from
  `PhoenixKit.Migrations.Repair.Probe`'s index snapshot — the same join that
  guards against double-listing an FK-referenced unique index (see that
  module's `@indexes_sql` comment) also hides a PK/UNIQUE-backing index from
  `kind: :index` lookups. Declaring the check as `kind: :constraint` instead
  — what they actually are on the catalog — fixed both; `@hand_declared_from`
  moved from 178 to 171 to keep this test exercising V171+.)
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Migrations.Repair.Report
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  # V178 is where hand-declaration started (the CRM party bridge); pinned to
  # 171 rather than 178 so this test also exercises the two composite-key
  # PRIMARY KEY objects fixed there (see moduledoc).
  @hand_declared_from 171

  test "hand-declared manifest objects match what the chain actually builds" do
    {:ok, report} = Repair.verify(prefix: "public", repo: Repo)

    offenders =
      report
      |> Report.findings()
      |> Enum.filter(
        &(&1.severity in [:error, :repairable] and (&1.since || 0) >= @hand_declared_from)
      )

    assert offenders == [],
           "the manifest disagrees with a chain-built schema for V#{@hand_declared_from}+:\n" <>
             Enum.map_join(offenders, "\n", & &1.message)
  end
end
