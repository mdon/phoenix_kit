defmodule Mix.Tasks.PhoenixKit.Gen.MigrationTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Gen.Migration

  # Regression (2026-07 quorum review): with no prior PhoenixKit migration
  # in the project (from_version == 0), the generated migration IS the
  # fresh install — a non-public schema may genuinely need creating, so
  # create_schema must not be hardcoded to false.
  test "fresh prefixed install (from_version 0) keeps schema creation" do
    content =
      Migration.migration_content("MyApp", "phoenix_kit_update_v0_to_v142", 0, 142, "auth")

    assert content =~ ~s(prefix: "auth")
    assert content =~ "create_schema: true"
  end

  test "prefixed upgrade never asks the chain to create the schema" do
    content =
      Migration.migration_content("MyApp", "phoenix_kit_update_v140_to_v142", 140, 142, "auth")

    assert content =~ ~s(prefix: "auth")
    assert content =~ "create_schema: false"
  end

  test "public installs never request schema creation" do
    for from <- [0, 140] do
      content =
        Migration.migration_content(
          "MyApp",
          "phoenix_kit_update_v#{from}_to_v142",
          from,
          142,
          "public"
        )

      assert content =~ "create_schema: false"
    end
  end
end
