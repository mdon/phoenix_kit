defmodule PhoenixKit.Migrations.Postgres.V157Test do
  @moduledoc """
  Pins the post-V157 schema shape — the suite's `ensure_current/2` runs the
  full chain (now past V157) before any test, same approach as
  `v156_test.exs`/`v158_test.exs`.

  Deliberately narrow: `annotations/annotation_kind_test.exs` already covers
  that BOTH layers accept `"image"` (the schema's `@kinds` and the DB CHECK),
  which is the regression V157 exists to prevent. What that file does not pin
  — and what this one does — is the CHECK's *whole* vocabulary. A later
  migration that re-states the constraint while dropping a kind would leave
  `annotation_kind_test.exs` green (it asserts the kinds it names are present,
  not that nothing else went missing) but silently break every annotation of
  the dropped kind, which is exactly the V130/V157 failure mode one step
  removed.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.RepoHelper, as: Repo

  # Every kind V157 leaves allowed. Ordered as the constraint declares them.
  @kinds ~w(rectangle circle polygon freehand callout text dimension line marker image)

  defp kind_check_def do
    %{rows: [[definition]]} =
      Repo.query!("""
      SELECT pg_get_constraintdef(c.oid)
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE c.conname = 'phoenix_kit_annotations_kind_check'
        AND t.relname = 'phoenix_kit_annotations'
        AND n.nspname = 'public'
      """)

    definition
  end

  describe "phoenix_kit_annotations_kind_check" do
    test "allows every kind V157 declares, and nothing was dropped along the way" do
      definition = kind_check_def()

      for kind <- @kinds do
        assert definition =~ "'#{kind}'", "kind_check no longer allows #{inspect(kind)}"
      end
    end

    test "the constraint accepts an image annotation at the DB level" do
      file_uuid = UUIDv7.generate()

      assert %{num_rows: 1} =
               Repo.query!(
                 """
                 INSERT INTO phoenix_kit_annotations (uuid, file_uuid, kind, geometry)
                 VALUES ($1, $2, 'image', '{"path": [[0, 0], [10, 10]]}'::jsonb)
                 """,
                 [UUIDv7.generate(), file_uuid]
               )
    end

    test "the constraint still rejects a kind outside the vocabulary" do
      assert_raise Postgrex.Error, ~r/phoenix_kit_annotations_kind_check/, fn ->
        Repo.query!(
          """
          INSERT INTO phoenix_kit_annotations (uuid, file_uuid, kind, geometry)
          VALUES ($1, $2, 'scribble', '{"path": [[0, 0], [10, 10]]}'::jsonb)
          """,
          [UUIDv7.generate(), UUIDv7.generate()]
        )
      end
    end
  end

  describe "version marker" do
    test "the chain ran past V157" do
      %{rows: [[version]]} =
        Repo.query!("""
        SELECT obj_description('public.phoenix_kit'::regclass, 'pg_class')
        """)

      assert String.to_integer(version) >= 157
    end
  end
end
