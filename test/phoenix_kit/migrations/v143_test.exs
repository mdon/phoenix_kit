defmodule PhoenixKit.Migrations.Postgres.V143Test do
  @moduledoc """
  Tests V143's schema state — newsletters Send Settings (send profiles).

  V143.up/down can't be invoked outside an `Ecto.Migrator` runner (they
  rely on `Ecto.Migration.execute/1` which checks for a runner process —
  same constraint as V106Test/V107Test/V112Test/V125Test). The schema is
  verified at boot: `test_helper.exs` runs `ensure_current/2` (now through
  V143) before any test, so these assertions pin the post-V143 shape and a
  regression that drops/re-adds the wrong thing surfaces here.
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

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  describe "phoenix_kit_newsletters_send_profiles table" do
    test "exists with the expected columns" do
      assert %{type: "uuid", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "uuid")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "name")

      assert %{type: "uuid", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "integration_uuid")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "provider_kind")

      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "from_name")

      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "from_email")

      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "reply_to")

      assert %{type: "text", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "signature_html")

      assert %{type: "text", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "signature_text")

      assert %{type: "integer", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "rate_per_hour")

      assert %{type: "integer", nullable: "YES"} =
               column("phoenix_kit_newsletters_send_profiles", "rate_per_day")

      assert %{type: "integer", nullable: "YES", default: "0"} =
               column("phoenix_kit_newsletters_send_profiles", "pause_seconds")

      assert %{type: "jsonb", nullable: "NO", default: default} =
               column("phoenix_kit_newsletters_send_profiles", "advanced")

      assert default =~ ~r/'\{\}'::jsonb/

      assert %{type: "boolean", nullable: "NO", default: "true"} =
               column("phoenix_kit_newsletters_send_profiles", "enabled")

      assert %{type: "boolean", nullable: "NO", default: "false"} =
               column("phoenix_kit_newsletters_send_profiles", "is_default")

      assert %{type: "timestamp with time zone", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "inserted_at")

      assert %{type: "timestamp with time zone", nullable: "NO"} =
               column("phoenix_kit_newsletters_send_profiles", "updated_at")
    end

    test "has an index on integration_uuid" do
      assert index_exists?("idx_nl_send_profiles_integration")
    end

    test "enforces at most one default profile via a partial unique index" do
      assert index_exists?("idx_nl_send_profiles_default")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_nl_send_profiles_default'"
        )

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "is_default = true"
    end

    test "two profiles may share one integration_uuid, but a second default is rejected" do
      {:ok, integration_uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

      insert = fn attrs ->
        Repo.query!(
          """
          INSERT INTO phoenix_kit_newsletters_send_profiles
            (name, integration_uuid, provider_kind, is_default)
          VALUES ($1, $2, $3, $4)
          """,
          [attrs.name, integration_uuid, "smtp", attrs.is_default]
        )
      end

      assert insert.(%{name: "Profile A", is_default: false})
      assert insert.(%{name: "Profile B", is_default: false})
      assert insert.(%{name: "Profile C (default)", is_default: true})

      assert_raise Postgrex.Error, fn ->
        insert.(%{name: "Profile D (also default)", is_default: true})
      end
    end
  end

  describe "phoenix_kit_newsletters_broadcasts.send_profile_uuid" do
    test "is a nullable uuid column" do
      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_newsletters_broadcasts", "send_profile_uuid")
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment reflects V143" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      assert comment == "143"
    end
  end
end
