defmodule PhoenixKit.Modules.Storage.BucketPersistenceTest do
  @moduledoc """
  `Storage.create_bucket/1` round-tripping an encrypted `secret_access_key`
  through the real `phoenix_kit_buckets` table.

  Specifically covers the varchar(255) overflow V175 widened the column to
  fix: `enc:v1:` + base64(iv+tag+ciphertext) runs ~1.6x the plaintext
  length, so a plaintext secret past ~158 chars used to raise a raw
  Postgres 22001 (value too long) on insert — the changeset never
  validated against it, the column just silently couldn't hold the
  ciphertext its own encryption step produced.
  """
  # async: false — setup below stamps the global `:phoenix_kit,
  # :secret_key_base` app env, which other concurrently-running async tests
  # (this one does a real DB round-trip between encrypting and decrypting,
  # widening the race window) could observe mid-test. Same rationale as
  # PhoenixKit.Integrations.EncryptionTest.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-bucket-persistence")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    :ok
  end

  test "persists an encrypted secret_access_key longer than the old varchar(255) ceiling" do
    long_secret = String.duplicate("x", 200)
    assert String.length(long_secret) > 158

    assert {:ok, bucket} =
             Storage.create_bucket(%{
               name: "Long Secret Bucket",
               provider: "s3",
               bucket_name: "my-bucket",
               access_key_id: "AKIAEXAMPLE",
               secret_access_key: long_secret
             })

    reloaded = Storage.get_bucket(bucket.uuid)

    assert reloaded.secret_access_key != long_secret
    assert String.starts_with?(reloaded.secret_access_key, "enc:v1:")
    assert Encryption.decrypt_value(reloaded.secret_access_key) == {:ok, long_secret}
  end
end
