defmodule PhoenixKit.Migrations.Postgres.V145Test do
  @moduledoc """
  Tests V145's schema state — newsletters Send Settings (send profiles).

  V145.up/down can't be invoked outside an `Ecto.Migrator` runner (they
  rely on `Ecto.Migration.execute/1` which checks for a runner process —
  same constraint as V106Test/V107Test/V112Test/V125Test). The schema is
  verified at boot: `test_helper.exs` runs `ensure_current/2` (now through
  V145) before any test, so these assertions pin the post-V145 shape and a
  regression that drops/re-adds the wrong thing surfaces here.

  V151 later moves the send-profile table itself to core Email and drops
  `phoenix_kit_newsletters_send_profiles` — those table/index assertions
  now live in `V151Test`. What's left here is `send_profile_uuid`, the
  one V145 change V151 doesn't touch.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  describe "phoenix_kit_newsletters_broadcasts.send_profile_uuid" do
    test "is a nullable uuid column" do
      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_newsletters_broadcasts", "send_profile_uuid")
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V145" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      # >= rather than ==: pinning the exact latest version breaks this
      # test every time a NEWER migration ships (V146 did exactly that).
      # What V145 owns is "the chain reached at least me".
      assert String.to_integer(comment) >= 145
    end
  end
end
