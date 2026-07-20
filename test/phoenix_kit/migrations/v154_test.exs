defmodule PhoenixKit.Migrations.Postgres.V154Test do
  @moduledoc """
  Tests V154's schema state — Delivery CRM contact id + per-broadcast
  dedup.

  V154.up/down can't be invoked outside an `Ecto.Migrator` runner — same
  constraint as V106Test/V107Test/V112Test/V125Test/V145Test/V152Test.
  The schema is verified at boot: `test_helper.exs` runs
  `ensure_current/2` (now through V154) before any test, so these
  assertions pin the post-V154 shape.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User

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

  defp insert_broadcast! do
    %{rows: [[uuid]]} =
      Repo.query!("""
      INSERT INTO phoenix_kit_newsletters_broadcasts (subject)
      VALUES ('V154 dedup test')
      RETURNING uuid
      """)

    uuid
  end

  defp insert_user! do
    %User{}
    |> User.guest_user_changeset(%{
      email: "v154-test-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
  end

  describe "phoenix_kit_newsletters_deliveries.crm_contact_uuid" do
    test "is a nullable, unconstrained uuid" do
      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_newsletters_deliveries", "crm_contact_uuid")
    end

    test "has a plain index" do
      assert index_exists?("idx_newsletters_deliveries_crm_contact")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_newsletters_deliveries_crm_contact'"
        )

      refute indexdef =~ "WHERE"
      refute indexdef =~ "UNIQUE"
    end
  end

  describe "recipient_check — widened, not XOR'd" do
    test "a row with neither user_uuid nor recipient_email is rejected" do
      broadcast_uuid = insert_broadcast!()

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries
                   (broadcast_uuid, user_uuid, recipient_email, crm_contact_uuid)
                 VALUES ($1, NULL, NULL, NULL)
                 """,
                 [broadcast_uuid]
               )
    end

    test "a row with only recipient_email set is accepted (crm_list delivery, unchanged)" do
      broadcast_uuid = insert_broadcast!()

      assert {:ok, %{num_rows: 1}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, recipient_email)
                 VALUES ($1, 'crm-contact@example.com')
                 """,
                 [broadcast_uuid]
               )
    end

    test "a row with only user_uuid set is accepted (newsletters_list delivery, unchanged)" do
      broadcast_uuid = insert_broadcast!()
      user = insert_user!()

      assert {:ok, %{num_rows: 1}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, user_uuid)
                 VALUES ($1, $2)
                 """,
                 [broadcast_uuid, Ecto.UUID.dump!(user.uuid)]
               )
    end

    test "a row with only crm_contact_uuid + recipient_email set is accepted (new CRM shape)" do
      broadcast_uuid = insert_broadcast!()
      {:ok, contact_uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert {:ok, %{num_rows: 1}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries
                   (broadcast_uuid, crm_contact_uuid, recipient_email)
                 VALUES ($1, $2, 'contact@example.com')
                 """,
                 [broadcast_uuid, contact_uuid]
               )
    end

    test "a row with only crm_contact_uuid set (no recipient_email) is rejected — still needs an address" do
      broadcast_uuid = insert_broadcast!()
      {:ok, contact_uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries
                   (broadcast_uuid, crm_contact_uuid, recipient_email)
                 VALUES ($1, $2, NULL)
                 """,
                 [broadcast_uuid, contact_uuid]
               )
    end

    test "a row with both user_uuid and crm_contact_uuid set is rejected — mutual exclusion" do
      broadcast_uuid = insert_broadcast!()
      user = insert_user!()
      {:ok, contact_uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 """
                 INSERT INTO phoenix_kit_newsletters_deliveries
                   (broadcast_uuid, user_uuid, crm_contact_uuid, recipient_email)
                 VALUES ($1, $2, $3, 'both-owners@example.com')
                 """,
                 [broadcast_uuid, Ecto.UUID.dump!(user.uuid), contact_uuid]
               )
    end
  end

  describe "per-broadcast dedup indexes" do
    test "unique on (broadcast_uuid, user_uuid) where user_uuid is not null" do
      assert index_exists?("idx_newsletters_deliveries_uniq_broadcast_user")

      broadcast_uuid = insert_broadcast!()
      user = insert_user!()
      user_uuid_bin = Ecto.UUID.dump!(user.uuid)

      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, user_uuid) VALUES ($1, $2)",
                 [broadcast_uuid, user_uuid_bin]
               )

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, user_uuid) VALUES ($1, $2)",
                 [broadcast_uuid, user_uuid_bin]
               )
    end

    test "unique on (broadcast_uuid, crm_contact_uuid) where crm_contact_uuid is not null" do
      assert index_exists?("idx_newsletters_deliveries_uniq_broadcast_contact")

      broadcast_uuid = insert_broadcast!()
      {:ok, contact_uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

      insert = fn ->
        Repo.query(
          """
          INSERT INTO phoenix_kit_newsletters_deliveries
            (broadcast_uuid, crm_contact_uuid, recipient_email)
          VALUES ($1, $2, 'dup-contact@example.com')
          """,
          [broadcast_uuid, contact_uuid]
        )
      end

      assert {:ok, _} = insert.()
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert.()
    end

    test "unique on (broadcast_uuid, recipient_email) where recipient_email is not null" do
      assert index_exists?("idx_newsletters_deliveries_uniq_broadcast_email")

      broadcast_uuid = insert_broadcast!()

      insert = fn ->
        Repo.query(
          "INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, recipient_email) VALUES ($1, 'dup@example.com')",
          [broadcast_uuid]
        )
      end

      assert {:ok, _} = insert.()
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert.()
    end

    test "two different broadcasts may each independently address the same recipient" do
      broadcast_a = insert_broadcast!()
      broadcast_b = insert_broadcast!()
      user = insert_user!()
      user_uuid_bin = Ecto.UUID.dump!(user.uuid)

      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, user_uuid) VALUES ($1, $2)",
                 [broadcast_a, user_uuid_bin]
               )

      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO phoenix_kit_newsletters_deliveries (broadcast_uuid, user_uuid) VALUES ($1, $2)",
                 [broadcast_b, user_uuid_bin]
               )
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V154" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      # >= rather than ==: pinning the exact latest version breaks this
      # test every time a NEWER migration ships.
      assert String.to_integer(comment) >= 154
    end
  end
end
