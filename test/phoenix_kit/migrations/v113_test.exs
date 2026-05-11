defmodule PhoenixKit.Migrations.Postgres.V113Test do
  @moduledoc """
  Tests V113's schema state.

  V113.up/down can't be invoked outside an `Ecto.Migrator` runner — they
  rely on `Ecto.Migration.execute/1` which checks for a runner process.
  Same constraint as V106Test / V107Test / V112Test. The schema is
  implicitly verified at boot by `test_helper.exs` which runs all
  migrations including V113 before any test; these assertions pin the
  post-V113 shape so a regression that drops / re-adds the wrong thing
  surfaces here.

  Five things are pinned:

  1. `system_managed BOOLEAN NOT NULL DEFAULT false` on `phoenix_kit_files`.
  2. `parent_file_uuid UUID` (nullable) on `phoenix_kit_files`, with the
     FK to itself ON DELETE CASCADE.
  3. `user_uuid` on `phoenix_kit_files` is now nullable (was NOT NULL).
  4. Three indexes: `phoenix_kit_files_parent_uuid_index`,
     `phoenix_kit_files_system_managed_index`,
     `phoenix_kit_files_system_dedup_index` (partial unique).
  5. CHECK constraint `phoenix_kit_files_user_or_parent_check`.

  Plus the new `phoenix_kit_comment_media` junction table and its two
  indexes.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp column_info(table, column) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    row
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_indexes WHERE indexname = $1
        )
        """,
        [name]
      )

    exists
  end

  defp constraint_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = $1
        )
        """,
        [name]
      )

    exists
  end

  describe "system_managed column" do
    test "exists on phoenix_kit_files as BOOLEAN NOT NULL DEFAULT false" do
      [data_type, is_nullable, default] = column_info("phoenix_kit_files", "system_managed")

      assert data_type == "boolean"
      assert is_nullable == "NO"
      assert default == "false"
    end
  end

  describe "parent_file_uuid column + self-FK" do
    test "exists as nullable UUID" do
      [data_type, is_nullable, _default] = column_info("phoenix_kit_files", "parent_file_uuid")

      assert data_type == "uuid"
      assert is_nullable == "YES"
    end

    test "FK constraint cascades on delete" do
      assert constraint_exists?("phoenix_kit_files_parent_file_uuid_fkey")

      %{rows: [[delete_action]]} =
        Repo.query!("""
        SELECT confdeltype FROM pg_constraint
        WHERE conname = 'phoenix_kit_files_parent_file_uuid_fkey'
        """)

      assert delete_action == "c"
    end
  end

  describe "user_uuid NOT NULL dropped" do
    test "is now nullable on phoenix_kit_files" do
      [_data_type, is_nullable, _default] = column_info("phoenix_kit_files", "user_uuid")

      assert is_nullable == "YES"
    end
  end

  describe "indexes" do
    test "parent_uuid index exists (partial: WHERE parent_file_uuid IS NOT NULL)" do
      assert index_exists?("phoenix_kit_files_parent_uuid_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_parent_uuid_index'
        """)

      assert indexdef =~ "WHERE (parent_file_uuid IS NOT NULL)"
    end

    test "system_managed index exists (partial: WHERE system_managed = false)" do
      assert index_exists?("phoenix_kit_files_system_managed_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_system_managed_index'
        """)

      assert indexdef =~ "WHERE (system_managed = false)"
    end

    test "system_dedup partial unique index exists on (parent_file_uuid, file_name)" do
      assert index_exists?("phoenix_kit_files_system_dedup_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_system_dedup_index'
        """)

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "parent_file_uuid"
      assert indexdef =~ "file_name"
      assert indexdef =~ "WHERE (system_managed = true)"
    end
  end

  describe "CHECK constraint: user_uuid OR parent_file_uuid" do
    test "constraint exists" do
      assert constraint_exists?("phoenix_kit_files_user_or_parent_check")
    end

    test "row with both user_uuid and parent_file_uuid NULL is rejected" do
      # Bypass the changeset; this test exists specifically to verify the
      # DB enforces the invariant when raw SQL bypasses Elixir validation.
      assert_raise Postgrex.Error, ~r/phoenix_kit_files_user_or_parent_check/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_files (
          uuid, original_file_name, file_name, file_path, mime_type,
          file_type, ext, file_checksum, user_file_checksum, size,
          status, system_managed, inserted_at, updated_at
        ) VALUES (
          uuid_generate_v7(), 'orphan.bin', 'orphan.bin', '/', 'application/octet-stream',
          'other', '.bin', 'x', 'x', 1,
          'active', false, NOW(), NOW()
        )
        """)
      end
    end
  end

  describe "phoenix_kit_comment_media junction table" do
    test "table exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_name = 'phoenix_kit_comment_media'
        )
        """)

      assert exists == true
    end

    test "unique index on (comment_uuid, position) exists" do
      assert index_exists?("phoenix_kit_comment_media_comment_position_index")
    end

    test "secondary index on file_uuid exists" do
      %{rows: [[count]]} =
        Repo.query!("""
        SELECT count(*) FROM pg_indexes
        WHERE tablename = 'phoenix_kit_comment_media'
          AND indexdef ~ 'file_uuid'
          AND indexname != 'phoenix_kit_comment_media_pkey'
        """)

      assert count >= 1
    end
  end
end
