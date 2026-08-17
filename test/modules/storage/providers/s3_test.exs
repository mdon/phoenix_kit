defmodule PhoenixKit.Modules.Storage.Providers.S3ResolveCredentialsTest do
  @moduledoc """
  `Providers.S3.resolve_credentials/1` — the one place a bucket's actual
  (plaintext) S3 credentials get produced, either by decrypting
  `secret_access_key` or by reading through a `PhoenixKit.Integrations`
  connection. `@doc false` and public for exactly this: testable without a
  real S3 endpoint (same rationale as `V174.repair_statements/1`).
  """
  # async: false — setup below stamps the global `:phoenix_kit,
  # :secret_key_base` app env, which other concurrently-running async tests
  # could observe mid-test. Same rationale as PhoenixKit.Integrations.EncryptionTest.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Providers.S3

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-s3-resolve")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    :ok
  end

  describe "direct credentials (no integration_uuid)" do
    test "decrypts an encrypted secret_access_key" do
      bucket = %Bucket{
        access_key_id: "AKIAEXAMPLE",
        secret_access_key: Encryption.encrypt_value("super-secret-value")
      }

      assert S3.resolve_credentials(bucket) == {"AKIAEXAMPLE", "super-secret-value"}
    end

    test "passes through a plaintext secret_access_key (e.g. the test_connection flow, which never persists through the changeset)" do
      bucket = %Bucket{access_key_id: "AKIAEXAMPLE", secret_access_key: "raw-plaintext"}

      assert S3.resolve_credentials(bucket) == {"AKIAEXAMPLE", "raw-plaintext"}
    end

    test "returns a nil secret when decryption fails (corrupted/undecryptable ciphertext)" do
      bucket = %Bucket{
        access_key_id: "AKIAEXAMPLE",
        secret_access_key: "enc:v1:not-valid-base64!!"
      }

      assert S3.resolve_credentials(bucket) == {"AKIAEXAMPLE", nil}
    end

    test "nil secret_access_key resolves to a nil secret" do
      bucket = %Bucket{access_key_id: "AKIAEXAMPLE", secret_access_key: nil}

      assert S3.resolve_credentials(bucket) == {"AKIAEXAMPLE", nil}
    end
  end

  describe "integration_uuid" do
    test "resolves access_key/secret_key from the referenced Integrations connection" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "test bucket integration")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIAFROMINTEGRATION",
          "secret_key" => "secret-from-integration",
          "aws_region" => "us-east-1"
        })

      bucket = %Bucket{integration_uuid: uuid, access_key_id: nil, secret_access_key: nil}

      assert S3.resolve_credentials(bucket) ==
               {"AKIAFROMINTEGRATION", "secret-from-integration"}
    end

    test "returns {nil, nil} when the integration_uuid does not resolve to a connected integration" do
      ghost_uuid = "00000000-0000-7000-8000-000000000000"
      bucket = %Bucket{integration_uuid: ghost_uuid}

      assert S3.resolve_credentials(bucket) == {nil, nil}
    end
  end
end
