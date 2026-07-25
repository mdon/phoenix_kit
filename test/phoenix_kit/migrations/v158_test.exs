defmodule PhoenixKit.Migrations.Postgres.V158Test do
  @moduledoc """
  Pins the post-V158 schema shape — the suite's `ensure_current/2` runs
  the full chain (now through V158) before any test, same approach as
  `v155_test.exs`/`v156_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.RepoHelper, as: Repo

  # `table_schema` anchored to public: `prefix_migration_test.exs` runs the
  # whole chain into a scratch schema on this same database, so an
  # unanchored lookup can match two rows if a crashed run leaves it behind.
  defp column(table, name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, name]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  describe "phoenix_kit_newsletters_broadcasts.attachments" do
    test "jsonb, NOT NULL, defaults to an empty array" do
      assert %{type: "jsonb", nullable: "NO", default: default} =
               column("phoenix_kit_newsletters_broadcasts", "attachments")

      assert default =~ "'[]'::jsonb"
    end

    test "the CHECK rejects a non-array value" do
      assert_raise Postgrex.Error, ~r/attachments_is_array/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_newsletters_broadcasts (subject, attachments)
        VALUES ('V158 shape check', '{"not": "an array"}'::jsonb)
        """)
      end
    end

    # `jsonb_typeof` has six results; the object case above is only one of the
    # five the CHECK must reject. A scalar is the shape a naive writer that
    # stores a single uuid without wrapping it would produce.
    test "the CHECK rejects a JSON scalar" do
      assert_raise Postgrex.Error, ~r/attachments_is_array/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_newsletters_broadcasts (subject, attachments)
        VALUES ('V158 scalar check', '"019f0000-0000-7000-8000-000000000001"'::jsonb)
        """)
      end
    end

    test "an array of uuids inserts cleanly and round-trips in order" do
      %{rows: [[attachments]]} =
        Repo.query!("""
        INSERT INTO phoenix_kit_newsletters_broadcasts (subject, attachments)
        VALUES ('V158 roundtrip', '["019f0000-0000-7000-8000-000000000001", "019f0000-0000-7000-8000-000000000002"]'::jsonb)
        RETURNING attachments
        """)

      assert attachments == [
               "019f0000-0000-7000-8000-000000000001",
               "019f0000-0000-7000-8000-000000000002"
             ]
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V158" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      assert String.to_integer(comment) >= 158
    end
  end
end
