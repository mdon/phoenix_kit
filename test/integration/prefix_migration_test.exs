defmodule PhoenixKit.Integration.PrefixMigrationTest do
  @moduledoc """
  Runs the full versioned migration chain into a named (non-`public`)
  schema — the `--prefix` install path.

  Regression coverage for the CREATE INDEX schema-qualification bug
  (fixed 2026-07-11): several migration helpers qualified the *index
  name* with the prefix (`CREATE INDEX prefix.name ON prefix.table`),
  which Postgres rejects outright — an index always lands in its
  table's schema, so only the table may be qualified. The default
  `public` path never executes those qualification branches, so only a
  full prefixed chain exercises this class of bug.

  ## Why sandbox `:auto` mode instead of a checkout

  `Ecto.Migrator` spawns its own runner process with its own
  connections, so a sandbox checkout can't cover it (see
  `PhoenixKit.MigrationTest` moduledoc). And running the chain through
  a second non-sandbox repo instance doesn't work either: V08's data
  backfill calls `Ecto.Adapters.SQL.query(RepoHelper.repo(), ...)`,
  which resolves the repo *module* name to the named instance and
  bypasses `put_dynamic_repo/1`. So this test mirrors the boot path
  instead: `test_helper.exs` runs `ensure_current/2` through the named
  repo while the sandbox is still in `:auto` mode — we flip back to
  `:auto` for the duration of the test and restore `:manual` after.
  Safe because `async: false` tests run serially, after all async
  tests have finished.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  # The full chain is 140+ versions — well past the default 60s.
  @moduletag timeout: :timer.minutes(5)

  @schema "pk_prefix_migration_test"

  test "full migration chain applies cleanly into a named schema" do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      # Restore :manual even if the schema drop raises — leaving the
      # sandbox in :auto would poison every later sync test.
      try do
        Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
    # Ecto's migrator needs the schema to pre-exist for its own
    # schema_migrations bookkeeping table.
    Repo.query!("CREATE SCHEMA #{@schema}")

    # The multi-step runner prints a progress bar unconditionally;
    # capture it so the suite output stays clean.
    capture_io(fn ->
      assert :ok =
               PhoenixKit.Migration.ensure_current(Repo,
                 prefix: @schema,
                 log: false
               )
    end)

    # The version marker must report the chain fully applied.
    %{rows: [[version_comment]]} =
      Repo.query!("SELECT obj_description('#{@schema}.phoenix_kit'::regclass, 'pg_class')")

    assert version_comment ==
             to_string(Postgres.current_version())

    # Spot-check the indexes built by the once-buggy CREATE sites
    # (uuid_fk_columns.ex, V56/V57 add_uuid_unique_indexes, V95): they
    # must exist and must live in the prefixed schema.
    %{rows: rows} =
      Repo.query!(
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND indexname = ANY($2)
        """,
        [
          @schema,
          [
            "phoenix_kit_users_tokens_user_uuid_idx",
            "phoenix_kit_role_assignments_user_uuid_role_uuid_idx",
            "phoenix_kit_role_permissions_role_uuid_module_key_idx",
            "phoenix_kit_oauth_providers_user_uuid_provider_idx",
            "phoenix_kit_media_folders_name_parent_idx"
          ]
        ]
      )

    found = rows |> List.flatten() |> Enum.sort()

    assert found == [
             "phoenix_kit_media_folders_name_parent_idx",
             "phoenix_kit_oauth_providers_user_uuid_provider_idx",
             "phoenix_kit_role_assignments_user_uuid_role_uuid_idx",
             "phoenix_kit_role_permissions_role_uuid_module_key_idx",
             "phoenix_kit_users_tokens_user_uuid_idx"
           ]

    # And the chain must have built a full complement of indexes in the
    # prefixed schema (142 versions produce 700+; a low count would mean
    # part of the chain silently skipped).
    %{rows: [[index_count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND tablename LIKE 'phoenix_kit%'",
        [@schema]
      )

    assert index_count > 500
  end
end
