defmodule PhoenixKit.Integrations.EncryptionTest do
  # async: false — the encryption_key/0 fallback tests mutate the global
  # `:phoenix_kit` app env (`:secret_key_base`, `:parent_module`), which
  # other concurrently-running async test files could observe mid-test.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Encryption

  describe "encrypt_fields/1 and decrypt_fields/1" do
    test "round-trips sensitive fields" do
      data = %{
        "provider" => "google",
        "auth_type" => "oauth2",
        "client_id" => "my-client-id",
        "client_secret" => "super-secret",
        "access_token" => "ya29.token123",
        "refresh_token" => "1//refresh456",
        "status" => "connected"
      }

      encrypted = Encryption.encrypt_fields(data)

      if Encryption.enabled?() do
        # Sensitive fields should be encrypted
        assert encrypted["client_secret"] != "super-secret"
        assert encrypted["access_token"] != "ya29.token123"
        assert encrypted["refresh_token"] != "1//refresh456"

        # Non-sensitive fields should be unchanged
        assert encrypted["provider"] == "google"
        assert encrypted["client_id"] == "my-client-id"
        assert encrypted["status"] == "connected"

        # Decrypt should restore originals
        decrypted = Encryption.decrypt_fields(encrypted)
        assert decrypted["client_secret"] == "super-secret"
        assert decrypted["access_token"] == "ya29.token123"
        assert decrypted["refresh_token"] == "1//refresh456"
        assert decrypted["provider"] == "google"
      else
        # Without secret_key_base, encryption is a no-op
        assert encrypted == data
      end
    end

    test "handles nil and empty values without error" do
      data = %{
        "provider" => "openrouter",
        "api_key" => nil,
        "access_token" => "",
        "status" => "disconnected"
      }

      encrypted = Encryption.encrypt_fields(data)
      assert encrypted["api_key"] == nil
      assert encrypted["access_token"] == ""

      decrypted = Encryption.decrypt_fields(encrypted)
      assert decrypted["api_key"] == nil
      assert decrypted["access_token"] == ""
    end

    test "does not re-encrypt already encrypted values" do
      if Encryption.enabled?() do
        data = %{"api_key" => "sk-test-key"}

        encrypted = Encryption.encrypt_fields(data)
        double_encrypted = Encryption.encrypt_fields(encrypted)

        # Should be the same — not double-encrypted
        assert encrypted["api_key"] == double_encrypted["api_key"]

        # Should decrypt to original
        assert Encryption.decrypt_fields(double_encrypted)["api_key"] == "sk-test-key"
      end
    end

    test "leaves non-encrypted values as-is on decrypt (backwards compatibility)" do
      data = %{
        "api_key" => "plaintext-key",
        "provider" => "openrouter"
      }

      # Decrypting unencrypted data should return it unchanged
      decrypted = Encryption.decrypt_fields(data)
      assert decrypted["api_key"] == "plaintext-key"
      assert decrypted["provider"] == "openrouter"
    end

    test "handles all auth type sensitive fields" do
      data = %{
        "access_token" => "token1",
        "refresh_token" => "token2",
        "client_secret" => "secret1",
        "api_key" => "key1",
        "bot_token" => "bot1",
        "secret_key" => "secret2"
      }

      encrypted = Encryption.encrypt_fields(data)
      decrypted = Encryption.decrypt_fields(encrypted)

      for field <- Encryption.sensitive_fields() do
        assert decrypted[field] == data[field],
               "Field #{field} did not round-trip correctly"
      end
    end

    test "decrypt_fields handles non-map input" do
      assert Encryption.decrypt_fields(nil) == nil
      assert Encryption.decrypt_fields("string") == "string"
    end

    test "encrypts and round-trips the smtp password field" do
      # `secret_key_base` isn't set as a flat `:phoenix_kit` app env key in
      # core's own test config (only nested under `PhoenixKitWeb.Endpoint`),
      # so this stamps one directly to make the round-trip meaningful.
      original = Application.get_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-password-encryption")

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_kit, :secret_key_base, original),
          else: Application.delete_env(:phoenix_kit, :secret_key_base)
      end)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"password" => "not-a-real-smtp-secret"})
      assert String.starts_with?(encrypted["password"], "enc:v1:")

      decrypted = Encryption.decrypt_fields(encrypted)
      assert decrypted["password"] == "not-a-real-smtp-secret"
    end
  end

  describe "encryption_key/0 fallback to host endpoint secret_key_base" do
    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test "flat key set takes precedence and is used" do
      Application.put_env(:phoenix_kit, :secret_key_base, "flat-secret-for-test")
      # Point parent_module somewhere that would resolve to a different,
      # real endpoint too — proves the flat key wins, not just that it's
      # present when no fallback is available.
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "falls back to the host endpoint's secret_key_base when the flat key is unset" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      # `PhoenixKitWeb.Endpoint` is core's own endpoint, started for the
      # test suite with a real `secret_key_base` — `parent_module: PhoenixKit`
      # resolves to it exactly like a host app's `parent_module` would
      # resolve to its own `MyAppWeb.Endpoint`.
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "returns nil (plaintext passthrough) when neither flat key nor endpoint is available" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      refute Encryption.enabled?()

      data = %{"api_key" => "plain"}
      assert Encryption.encrypt_fields(data) == data
    end
  end

  describe "sensitive_fields/0" do
    test "returns expected fields" do
      fields = Encryption.sensitive_fields()
      assert "access_token" in fields
      assert "refresh_token" in fields
      assert "client_secret" in fields
      assert "api_key" in fields
      assert "bot_token" in fields
      assert "secret_key" in fields
      assert "password" in fields
    end
  end

  describe "encrypt_value/1, decrypt_value/1 and encrypted?/1" do
    setup do
      # Same rationale as the "smtp password field" test above: stamp a flat
      # secret_key_base directly so encryption is deterministically enabled,
      # regardless of what core's own test config carries.
      original = Application.get_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-value-encryption")

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_kit, :secret_key_base, original),
          else: Application.delete_env(:phoenix_kit, :secret_key_base)
      end)

      :ok
    end

    test "round-trips a single value" do
      encrypted = Encryption.encrypt_value("s3-secret-key")

      assert encrypted != "s3-secret-key"
      assert String.starts_with?(encrypted, "enc:v1:")
      assert Encryption.encrypted?(encrypted)
      assert Encryption.decrypt_value(encrypted) == {:ok, "s3-secret-key"}
    end

    test "is idempotent — does not double-encrypt an already-encrypted value" do
      once = Encryption.encrypt_value("plaintext")
      twice = Encryption.encrypt_value(once)

      assert once == twice
      assert Encryption.decrypt_value(twice) == {:ok, "plaintext"}
    end

    test "nil and empty values pass through unchanged" do
      assert Encryption.encrypt_value(nil) == nil
      assert Encryption.encrypt_value("") == ""
      assert Encryption.decrypt_value(nil) == {:ok, nil}
      assert Encryption.decrypt_value("") == {:ok, ""}
    end

    test "decrypt_value passes through legacy plaintext (no enc:v1: prefix) unchanged" do
      assert Encryption.decrypt_value("legacy-plaintext-secret") ==
               {:ok, "legacy-plaintext-secret"}
    end

    test "encrypted?/1 detects the enc:v1: prefix" do
      refute Encryption.encrypted?("plaintext")
      refute Encryption.encrypted?(nil)
      assert Encryption.encrypted?(Encryption.encrypt_value("x"))
    end
  end

  describe "encrypt_value/1 and decrypt_value/1 when encryption is unavailable" do
    import ExUnit.CaptureLog

    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      on_exit(fn ->
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      refute Encryption.enabled?()
      :ok
    end

    test "encrypt_value/1 returns the value unchanged and logs a warning naming the function, not the value" do
      log =
        capture_log(fn ->
          assert Encryption.encrypt_value("s3-secret-should-not-be-logged") ==
                   "s3-secret-should-not-be-logged"
        end)

      assert log =~ "encrypt_value/1"
      assert log =~ "no encryption key available"
      refute log =~ "s3-secret-should-not-be-logged"
    end

    test "decrypt_value/1 returns {:error, :encryption_unavailable} for an already-encrypted value — never the ciphertext or a fabricated plaintext" do
      # Shape of a real enc:v1: value — this test only needs the prefix to
      # be recognized as "encrypted", not a value that decrypts cleanly.
      still_prefixed = "enc:v1:" <> Base.encode64(:crypto.strong_rand_bytes(40))

      assert Encryption.decrypt_value(still_prefixed) == {:error, :encryption_unavailable}
    end

    test "decrypt_value/1 still passes through legacy plaintext (no prefix) even with no key" do
      assert Encryption.decrypt_value("legacy-plaintext-secret") ==
               {:ok, "legacy-plaintext-secret"}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)
end
