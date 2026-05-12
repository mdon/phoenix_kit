defmodule PhoenixKit.Migrations.Postgres.V114Test do
  @moduledoc """
  Tests V114's data rewrite from composite-key storage
  (`integration:<provider>:<name>`) to uuid-only storage (`key = uuid`,
  provider + name in JSONB).

  V114.up/down can't be invoked outside an `Ecto.Migrator` runner —
  they rely on `Ecto.Migration.execute/1` which checks for a runner
  process. Instead, this test runs the same UPDATE statements
  directly via `Repo.query`, which is what we actually care about:
  that the rewrite logic picks the right key, fills JSONB correctly,
  and handles edge cases (legacy V0 keyless shape, idempotence,
  collision suffixing on rollback).

  The schema change itself is implicitly verified by
  `test_helper.exs` running every core migration including V114
  before tests — any test that depends on the new storage shape
  would fail at boot if V114 hadn't run.
  """

  use PhoenixKit.DataCase, async: false

  # Drift-detection: this test's `run_up!` / `run_down!` helpers copy
  # the SQL from `v114.ex`. The annotation forces this test to
  # recompile whenever the migration changes, so a maintainer who
  # tweaks the SQL without updating the test helpers gets a fresh
  # compile here and a chance to re-eyeball the duplicated SQL. It
  # does NOT auto-sync the strings — that would need a shared `.sql`
  # fixture; this is the cheap version.
  @external_resource Path.expand("../../../lib/phoenix_kit/migrations/postgres/v114.ex", __DIR__)

  alias PhoenixKit.Test.Repo

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Insert a row at an arbitrary key (composite or uuid-shaped) with the
  # given JSONB body and `module`. Mirrors how a pre-V114 row would have
  # been written by old `add_connection/3`. JSON is inlined as a literal
  # so PostgreSQL parses it as a JSONB object directly (passing through
  # `$N::jsonb` double-encodes via Postgrex's string handling).
  defp insert_setting!(key, value_json, module) do
    json_literal = value_json |> Jason.encode!() |> String.replace("'", "''")

    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_settings (key, value_json, module, date_added, date_updated)
        VALUES ($1, '#{json_literal}'::jsonb, $2, NOW(), NOW())
        RETURNING uuid
        """,
        [key, module]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  defp read_row(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)

    %{rows: [[key, value_json, module]]} =
      Repo.query!(
        "SELECT key, value_json, module FROM phoenix_kit_settings WHERE uuid = $1",
        [dumped]
      )

    %{key: key, value_json: value_json, module: module}
  end

  # Runs V114.up's UPDATE statement verbatim against the current DB.
  # Mirrors the SQL in `lib/phoenix_kit/migrations/postgres/v114.ex`.
  defp run_up! do
    Repo.query!("""
    UPDATE phoenix_kit_settings AS s
       SET key = s.uuid::text,
           module = 'integrations',
           value_json = COALESCE(s.value_json, '{}'::jsonb)
                        || jsonb_build_object(
                             'provider',
                             COALESCE(
                               NULLIF(s.value_json->>'provider', ''),
                               split_part(substring(s.key from 13), ':', 1)
                             ),
                             'name',
                             COALESCE(
                               NULLIF(s.value_json->>'name', ''),
                               NULLIF(split_part(substring(s.key from 13), ':', 2), ''),
                               'default'
                             )
                           )
     WHERE s.key LIKE 'integration:%';
    """)
  end

  # Runs V114.down's UPDATE statement verbatim. Reverses the up rewrite,
  # collision-suffixing on duplicate (provider, name) pairs. Suffix
  # source is `substring(uuid::text from 25 for 8)` — the random tail of
  # UUIDv7, not the timestamp prefix; see the moduledoc in `v114.ex` for
  # why.
  defp run_down! do
    Repo.query!("""
    WITH ordered AS (
      SELECT
        s.uuid,
        s.value_json->>'provider' AS provider,
        s.value_json->>'name'     AS name,
        ROW_NUMBER() OVER (
          PARTITION BY s.value_json->>'provider', s.value_json->>'name'
          ORDER BY s.date_added NULLS LAST, s.uuid
        ) AS rn
      FROM phoenix_kit_settings s
      WHERE s.module = 'integrations'
        AND s.key = s.uuid::text
    )
    UPDATE phoenix_kit_settings AS s
       SET key = 'integration:' || o.provider || ':' ||
                 CASE
                   WHEN o.rn = 1 THEN o.name
                   ELSE o.name || '-' || substring(s.uuid::text from 25 for 8)
                 END
      FROM ordered o
     WHERE s.uuid = o.uuid;
    """)
  end

  # ---------------------------------------------------------------------------
  # V114.up
  # ---------------------------------------------------------------------------

  describe "V114.up — composite-key → uuid-only rewrite" do
    test "rewrites integration:<provider>:<name> rows so key = uuid" do
      uuid =
        insert_setting!(
          "integration:openrouter:work",
          %{"api_key" => "sk-or-test", "status" => "connected"},
          "integrations"
        )

      run_up!()

      row = read_row(uuid)
      assert row.key == uuid
      assert row.module == "integrations"
      assert row.value_json["provider"] == "openrouter"
      assert row.value_json["name"] == "work"
      # Pre-existing fields preserved.
      assert row.value_json["api_key"] == "sk-or-test"
      assert row.value_json["status"] == "connected"
    end

    test "backfills missing name from key suffix when JSONB lacks 'name'" do
      uuid = insert_setting!("integration:google:personal", %{}, "integrations")

      run_up!()

      row = read_row(uuid)
      assert row.value_json["name"] == "personal"
      assert row.value_json["provider"] == "google"
    end

    test "preserves an existing JSONB 'name' over the key suffix" do
      # Edge case: JSONB body has a name that disagrees with the key
      # (drift from a pre-V114 buggy save). The JSONB value wins —
      # it's what consumers see at runtime, and rewriting it back to
      # the key suffix could mask the operator's actual choice.
      uuid =
        insert_setting!(
          "integration:openrouter:slug-from-key",
          %{"name" => "Display Name", "provider" => "openrouter"},
          "integrations"
        )

      run_up!()

      row = read_row(uuid)
      assert row.value_json["name"] == "Display Name"
      assert row.value_json["provider"] == "openrouter"
    end

    test "treats legacy V0 bare-provider key (no :name segment) as 'default'" do
      # `integration:google` without a `:name` segment was the original
      # 1-connection-per-provider shape pre-named-connections. Rewrite
      # should still work — name becomes "default".
      uuid = insert_setting!("integration:google", %{"client_id" => "cid"}, "integrations")

      run_up!()

      row = read_row(uuid)
      assert row.key == uuid
      assert row.value_json["provider"] == "google"
      assert row.value_json["name"] == "default"
      assert row.value_json["client_id"] == "cid"
    end

    test "stamps module='integrations' even if it was missing before" do
      # Edge: a row pre-dating `@settings_module` stamping might have
      # NULL module. V114.up should set it during the rewrite so the
      # new query path (filter by module) finds the row.
      uuid =
        insert_setting!("integration:openrouter:old", %{"api_key" => "k"}, nil)

      run_up!()

      row = read_row(uuid)
      assert row.module == "integrations"
    end

    test "ignores non-integration rows (key doesn't start with 'integration:')" do
      # Unrelated settings should not be touched.
      uuid = insert_setting!("project_title", %{"value" => "My App"}, nil)

      run_up!()

      row = read_row(uuid)
      assert row.key == "project_title"
      # Module not stamped (V114 only stamps rows it's actually
      # rewriting; this row matches no clause).
      assert row.module == nil
    end

    test "is idempotent — already-rewritten rows are no-ops on re-run" do
      uuid =
        insert_setting!(
          "integration:openrouter:once",
          %{"api_key" => "k"},
          "integrations"
        )

      run_up!()
      row_after_first = read_row(uuid)

      run_up!()
      row_after_second = read_row(uuid)

      assert row_after_first == row_after_second
    end
  end

  # ---------------------------------------------------------------------------
  # V114.down
  # ---------------------------------------------------------------------------

  describe "V114.down — uuid-only → composite-key rewrite" do
    test "rewrites key = uuid back to integration:<provider>:<name>" do
      # Start in the new shape (key = uuid).
      uuid =
        insert_setting!(
          # Garbage key — will be overwritten by run_up! to equal the row's uuid.
          "integration:openrouter:will-be-rewritten",
          %{"provider" => "openrouter", "name" => "work", "api_key" => "k"},
          "integrations"
        )

      run_up!()
      assert read_row(uuid).key == uuid

      run_down!()

      row = read_row(uuid)
      assert row.key == "integration:openrouter:work"
    end

    test "suffixes -<short uuid> on (provider, name) collisions" do
      # Two rows in the new shape with the same provider + name in
      # JSONB. V114.down has to disambiguate via uuid suffix because
      # the old shape can't represent duplicates.
      uuid1 =
        insert_setting!(
          "integration:openrouter:placeholder-a",
          %{"provider" => "openrouter", "name" => "work"},
          "integrations"
        )

      uuid2 =
        insert_setting!(
          "integration:openrouter:placeholder-b",
          %{"provider" => "openrouter", "name" => "work"},
          "integrations"
        )

      run_up!()
      run_down!()

      key1 = read_row(uuid1).key
      key2 = read_row(uuid2).key

      # One row keeps the plain composite key; the other gets a uuid
      # suffix. Both share the `integration:openrouter:work` prefix.
      assert key1 != key2

      assert key1 == "integration:openrouter:work" or
               String.starts_with?(key1, "integration:openrouter:work-")

      assert key2 == "integration:openrouter:work" or
               String.starts_with?(key2, "integration:openrouter:work-")

      # Exactly one row got the plain key; the other got the suffixed one.
      plain_keys = Enum.count([key1, key2], &(&1 == "integration:openrouter:work"))
      assert plain_keys == 1
    end

    test "N >= 3 collision: exactly one plain key, N-1 distinct suffixed keys" do
      # `ROW_NUMBER() OVER (PARTITION BY provider, name ORDER BY
      # date_added NULLS LAST, uuid)` should keep rn=1 plain and
      # suffix the rest with their own uuid prefixes — so three
      # rows sharing `(openrouter, work)` produce one plain key and
      # two distinct suffixed keys, never two plain ones or two
      # rows colliding on the same suffix.
      uuids =
        for i <- 1..3 do
          insert_setting!(
            "integration:openrouter:placeholder-#{i}",
            %{"provider" => "openrouter", "name" => "work"},
            "integrations"
          )
        end

      run_up!()
      run_down!()

      keys = Enum.map(uuids, &read_row(&1).key)

      # Exactly one plain key, exactly two suffixed keys.
      plain_count = Enum.count(keys, &(&1 == "integration:openrouter:work"))
      assert plain_count == 1

      suffixed = Enum.reject(keys, &(&1 == "integration:openrouter:work"))
      assert length(suffixed) == 2

      # All keys distinct (no suffix collision).
      assert length(Enum.uniq(keys)) == 3

      # Every suffixed key still shares the `integration:openrouter:work-` prefix.
      assert Enum.all?(suffixed, &String.starts_with?(&1, "integration:openrouter:work-"))
    end
  end
end
