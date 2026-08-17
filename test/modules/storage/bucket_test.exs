defmodule PhoenixKit.Modules.Storage.BucketTest do
  @moduledoc """
  `Bucket.changeset/2`'s credential handling: `secret_access_key` is
  encrypted at rest, and `integration_uuid` (an alternative credential
  source) is mutually exclusive with the bucket's own
  `access_key_id`/`secret_access_key` — never two sources of truth for the
  same secret.
  """
  # async: false — stamps the global `:phoenix_kit, :secret_key_base` app env
  # to make encryption deterministically enabled, same rationale as
  # PhoenixKit.Integrations.EncryptionTest.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage.Bucket

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-bucket-encryption")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    :ok
  end

  describe "local bucket" do
    test "is valid without any credentials" do
      changeset = Bucket.changeset(%Bucket{}, %{name: "Local SSD", provider: "local"})
      assert changeset.valid?
    end
  end

  describe "cloud bucket with direct credentials" do
    test "encrypts secret_access_key" do
      changeset =
        Bucket.changeset(%Bucket{}, %{
          name: "Prod S3",
          provider: "s3",
          bucket_name: "my-bucket",
          access_key_id: "AKIAEXAMPLE",
          secret_access_key: "super-secret-value"
        })

      assert changeset.valid?
      stored = Ecto.Changeset.get_field(changeset, :secret_access_key)

      assert stored != "super-secret-value"
      assert String.starts_with?(stored, "enc:v1:")
      assert Encryption.decrypt_value(stored) == {:ok, "super-secret-value"}

      # access_key_id is an identifier, not a secret — left as-is
      assert Ecto.Changeset.get_field(changeset, :access_key_id) == "AKIAEXAMPLE"
    end

    test "is idempotent — does not double-encrypt an already-encrypted value" do
      bucket = %Bucket{secret_access_key: Encryption.encrypt_value("super-secret-value")}

      changeset =
        Bucket.changeset(bucket, %{
          name: "Prod S3",
          provider: "s3",
          bucket_name: "my-bucket",
          access_key_id: "AKIAEXAMPLE",
          secret_access_key: bucket.secret_access_key
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :secret_access_key) == bucket.secret_access_key
      assert Encryption.decrypt_value(bucket.secret_access_key) == {:ok, "super-secret-value"}
    end

    test "an update that never touches secret_access_key still encrypts a legacy plaintext value" do
      # Simulates a pre-fix row: secret_access_key was written before
      # encryption existed, so it's plaintext in the struct loaded from the
      # DB. Any save — even one that only changes an unrelated field —
      # opportunistically migrates it, since the changeset always re-derives
      # the effective value via get_field (struct fallback included), not
      # just get_change.
      bucket = %Bucket{
        name: "Legacy S3",
        provider: "s3",
        bucket_name: "my-bucket",
        access_key_id: "AKIAEXAMPLE",
        secret_access_key: "legacy-plaintext-secret",
        priority: 0
      }

      changeset = Bucket.changeset(bucket, %{priority: 1})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :priority) == 1

      stored = Ecto.Changeset.get_field(changeset, :secret_access_key)
      assert stored != "legacy-plaintext-secret"
      assert Encryption.decrypt_value(stored) == {:ok, "legacy-plaintext-secret"}
    end

    test "requires bucket_name and a credential source" do
      changeset = Bucket.changeset(%Bucket{}, %{name: "Prod S3", provider: "s3"})

      refute changeset.valid?

      assert %{bucket_name: _, access_key_id: _, secret_access_key: _} =
               errors_by_field(changeset)
    end
  end

  describe "cloud bucket with integration_uuid" do
    @integration_uuid "019b669c-3c9d-7256-8ed1-edbc6ae29703"

    test "is valid with no access_key_id/secret_access_key of its own" do
      changeset =
        Bucket.changeset(%Bucket{}, %{
          name: "Prod S3 via integration",
          provider: "s3",
          bucket_name: "my-bucket",
          integration_uuid: @integration_uuid
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :access_key_id) == nil
      assert Ecto.Changeset.get_field(changeset, :secret_access_key) == nil
    end

    test "rejects integration_uuid set alongside access_key_id" do
      changeset =
        Bucket.changeset(%Bucket{}, %{
          name: "Conflicting",
          provider: "s3",
          bucket_name: "my-bucket",
          integration_uuid: @integration_uuid,
          access_key_id: "AKIAEXAMPLE"
        })

      refute changeset.valid?

      assert ("clear access_key_id and secret_access_key before setting integration_uuid " <>
                "(or clear integration_uuid to use direct credentials instead) — only one " <>
                "credential source at a time") in errors_on(changeset, :integration_uuid)
    end

    test "rejects integration_uuid set alongside secret_access_key" do
      changeset =
        Bucket.changeset(%Bucket{}, %{
          name: "Conflicting",
          provider: "s3",
          bucket_name: "my-bucket",
          integration_uuid: @integration_uuid,
          secret_access_key: "super-secret-value"
        })

      refute changeset.valid?

      assert ("clear access_key_id and secret_access_key before setting integration_uuid " <>
                "(or clear integration_uuid to use direct credentials instead) — only one " <>
                "credential source at a time") in errors_on(changeset, :integration_uuid)
    end

    test "rejects integration_uuid alongside direct credentials even for a local bucket" do
      changeset =
        Bucket.changeset(%Bucket{}, %{
          name: "Weird local",
          provider: "local",
          integration_uuid: @integration_uuid,
          secret_access_key: "super-secret-value"
        })

      refute changeset.valid?

      assert ("clear access_key_id and secret_access_key before setting integration_uuid " <>
                "(or clear integration_uuid to use direct credentials instead) — only one " <>
                "credential source at a time") in errors_on(changeset, :integration_uuid)
    end

    test "rejects setting integration_uuid on a bucket that already has direct credentials, even when this change doesn't touch them" do
      bucket = %Bucket{
        name: "Existing S3",
        provider: "s3",
        bucket_name: "my-bucket",
        access_key_id: "AKIAEXAMPLE",
        secret_access_key: Encryption.encrypt_value("super-secret-value")
      }

      changeset = Bucket.changeset(bucket, %{integration_uuid: @integration_uuid})

      refute changeset.valid?

      assert ("clear access_key_id and secret_access_key before setting integration_uuid " <>
                "(or clear integration_uuid to use direct credentials instead) — only one " <>
                "credential source at a time") in errors_on(changeset, :integration_uuid)
    end
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end

  defp errors_by_field(changeset) do
    Map.new(changeset.errors, fn {field, _} -> {field, true} end)
  end
end
