defmodule PhoenixKit.Integration.KeyRotationTest do
  @moduledoc """
  Exercises `PhoenixKit.Integrations.KeyRotation` against real database rows
  — a fact-based check of whether changing the encryption key actually
  preserves saved integrations, or silently strands them.

  ## What "row locking (concurrent-write safety)" below does and doesn't prove

  It confirms, via `Ecto.Adapters.SQL.to_sql/3` on the exact query
  `KeyRotation.locked_rows_query/0` builds, that the row-fetch is genuinely
  `SELECT ... FOR UPDATE` — not merely claimed in a comment. It does NOT drive
  a genuine two-connection race (a second transaction actually blocking on
  the lock, then observing the rotated value once released): that needs two
  independently-committing connections coordinated around the lock, which
  is more infrastructure than a single-process ExUnit test naturally
  provides — the same call `PhoenixKit.Integration.RepairTest` makes for
  its own S18 concurrent-migration scenario (see that file's moduledoc).
  The SQL-fact check here is what makes the guarantee inspectable without
  that infrastructure: `FOR UPDATE` is a standard, well-defined Postgres
  primitive — once it's confirmed to be in the actual query, the blocking
  behavior it provides is a property of Postgres, not of this test suite.
  """
  use PhoenixKit.DataCase, async: false

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyRotation
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting

  setup do
    original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

    on_exit(fn ->
      restore_env(:integrations_encryption_key, original_dedicated)
      restore_env(:secret_key_base, original_flat)
    end)

    # Every test starts from the most common real scenario: no dedicated
    # key yet, everything encrypted under the legacy secret_key_base tier.
    Application.delete_env(:phoenix_kit, :integrations_encryption_key)
    Application.put_env(:phoenix_kit, :secret_key_base, "current-secret-under-test")

    :ok
  end

  defp seed_connection(provider, name, attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    {:ok, _} = Integrations.save_setup(uuid, attrs)
    uuid
  end

  defp raw_value_json(uuid), do: Queries.get_setting_by_uuid(uuid).value_json

  defp corrupt_row!(uuid, plaintext_field, secret) do
    corrupted = Encryption.encrypt_fields_with_secret(%{"api_key" => plaintext_field}, secret)

    uuid
    |> Queries.get_setting_by_uuid()
    |> Setting.update_changeset(%{value_json: corrupted})
    |> Queries.update_setting()

    corrupted
  end

  describe "rotate/2 — real run" do
    test "re-encrypts every connection under the new secret; the old key can no longer read it" do
      uuid1 = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      uuid2 = seed_connection("openrouter", "two", %{"api_key" => "sk-two"})

      before1 = raw_value_json(uuid1)
      assert String.starts_with?(before1["api_key"], "enc:v1:")

      assert {:ok, %{rotated: 2, dry_run: false}} = KeyRotation.rotate("brand-new-secret")

      after1 = raw_value_json(uuid1)
      after2 = raw_value_json(uuid2)

      # Ciphertext actually changed (new key, new random IV).
      refute after1["api_key"] == before1["api_key"]

      # The OLD key is still the active config (rotation never flips it) —
      # it must no longer be able to read the row. This is the exact
      # silent-corruption path the decrypt-failure fix guards, exercised
      # end to end through a real rotation.
      refute Map.has_key?(Encryption.decrypt_fields(after1), "api_key")

      # The NEW secret, once configured as the active key, round-trips —
      # proving rotation wrote something *usable*, not just something new.
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "brand-new-secret")
      assert Encryption.decrypt_fields(after1)["api_key"] == "sk-one"
      assert Encryption.decrypt_fields(after2)["api_key"] == "sk-two"
    end

    test "a connection with no sensitive fields rotates as a no-op and stays readable" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "empty")

      assert {:ok, %{rotated: 1}} = KeyRotation.rotate("brand-new-secret")

      Application.put_env(:phoenix_kit, :integrations_encryption_key, "brand-new-secret")

      assert {:ok, %{provider: "openrouter"}} =
               Integrations.get_integration_by_uuid(uuid, :system)
    end

    test "aborts and writes NOTHING when any row fails to decrypt under the current key" do
      uuid_good = seed_connection("openrouter", "good", %{"api_key" => "sk-good"})
      uuid_bad = seed_connection("openrouter", "bad", %{"api_key" => "sk-bad"})

      before_good = raw_value_json(uuid_good)
      # Simulate `uuid_bad` already being encrypted under a DIFFERENT secret
      # than the one currently active — e.g. a prior partial/manual change.
      corrupted = corrupt_row!(uuid_bad, "sk-bad", "some-other-secret")

      assert {:error, {:decrypt_failed, failed_uuid, :decrypt_failed_under_current_key}} =
               KeyRotation.rotate("brand-new-secret")

      assert failed_uuid == uuid_bad

      # Nothing was written — not even the row that decrypted fine.
      assert raw_value_json(uuid_good) == before_good
      assert raw_value_json(uuid_bad) == corrupted
    end
  end

  describe "rotate/2 — dry_run" do
    test "reports the count without writing anything" do
      uuid = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      before = raw_value_json(uuid)

      assert {:ok, %{rotated: 1, dry_run: true}} = KeyRotation.rotate("unused", dry_run: true)

      assert raw_value_json(uuid) == before
    end

    test "surfaces the same decrypt failure a real run would, without writing" do
      uuid = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      corrupt_row!(uuid, "sk-one", "some-other-secret")

      assert {:error, {:decrypt_failed, ^uuid, :decrypt_failed_under_current_key}} =
               KeyRotation.rotate("unused", dry_run: true)
    end
  end

  describe "row locking (concurrent-write safety) — what it does and does not prove" do
    test "the real-rotation row-fetch query is a genuine SELECT ... FOR UPDATE" do
      {sql, _params} =
        EctoSQL.to_sql(
          :all,
          PhoenixKit.RepoHelper.repo(),
          KeyRotation.locked_rows_query()
        )

      assert sql =~ "FOR UPDATE"
    end

    test "the dry-run row-fetch query takes NO lock — a dry run must never block a live writer" do
      {sql, _params} =
        EctoSQL.to_sql(
          :all,
          PhoenixKit.RepoHelper.repo(),
          KeyRotation.rotate_rows_query()
        )

      refute sql =~ "FOR UPDATE"
    end
  end

  describe "rotate/2 — encryption not active" do
    test "refuses to run when integration_encryption_enabled is false" do
      original = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      on_exit(fn -> restore_env(:integration_encryption_enabled, original) end)
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert {:error, {:encryption_disabled, :disabled_explicit}} =
               KeyRotation.rotate("some-secret")
    end

    test "refuses to run when no key resolves at all" do
      original_parent = Application.get_env(:phoenix_kit, :parent_module)
      on_exit(fn -> restore_env(:parent_module, original_parent) end)

      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert {:error, {:encryption_disabled, :disabled_no_key}} =
               KeyRotation.rotate("some-secret")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)
end
