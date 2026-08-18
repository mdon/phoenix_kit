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

  describe "decrypt failure safety (active key does not match the encrypting key)" do
    import ExUnit.CaptureLog

    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
      end)

      :ok
    end

    test "an undecryptable field is dropped, never handed back as raw ciphertext" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")

      # Simulate a key change made without running the rotation task first —
      # exactly the condition that must trip this safety net.
      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      decrypted = Encryption.decrypt_fields(encrypted)

      # The field must be ABSENT, not the leftover "enc:v1:..." string — a
      # caller checking `data["api_key"]` for presence must see nothing,
      # not something that merely fails to work as a real credential.
      refute Map.has_key?(decrypted, "api_key")
    end

    test "logs the decrypt failure instead of failing silently" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      log = capture_log(fn -> Encryption.decrypt_fields(encrypted) end)

      assert log =~ "Failed to decrypt field"
      assert log =~ "api_key"
    end

    test "a non-sensitive field is untouched when a sensitive field on the same row fails to decrypt" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "will-become-unreadable",
          "provider" => "openrouter"
        })

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      decrypted = Encryption.decrypt_fields(encrypted)
      refute Map.has_key?(decrypted, "api_key")
      assert decrypted["provider"] == "openrouter"
    end

    test "a corrupted field's decrypt failure does not affect a sibling sensitive field still decryptable under the same key" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "will-be-corrupted",
          "bot_token" => "stays-readable"
        })

      # The active key never changes in this test — only this ONE field's
      # stored bytes are damaged (truncated, breaking base64 decoding).
      # Proves a per-field decrypt failure doesn't cascade to a SENSITIVE
      # sibling field that decrypts fine under the same, still-active key —
      # the thing the old test's name promised and its body never checked.
      corrupted = Map.update!(encrypted, "api_key", &String.slice(&1, 0..-6//1))

      decrypted = Encryption.decrypt_fields(corrupted)
      refute Map.has_key?(decrypted, "api_key")
      assert decrypted["bot_token"] == "stays-readable"
    end
  end

  describe "decrypt_fields_with_failures/1 — the write-side companion" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test "reports a field that failed to decrypt by name, in addition to dropping it" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      {decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      refute Map.has_key?(decrypted, "api_key")
      assert failed == ["api_key"]
    end

    test "returns the same map decrypt_fields/1 would, with an empty failure list, when everything decrypts" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{"api_key" => "sk-live", "provider" => "openrouter"})

      {decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      assert decrypted == Encryption.decrypt_fields(encrypted)
      assert failed == []
    end

    test "reports every field that failed, not just the first" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "sk-live",
          "bot_token" => "bot-live"
        })

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      {_decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      assert Enum.sort(failed) == ["api_key", "bot_token"]
    end

    test "returns an empty failure list when encryption is disabled (nothing to fail)" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      refute Encryption.enabled?()

      data = %{"api_key" => "plain"}
      assert Encryption.decrypt_fields_with_failures(data) == {data, []}
    end
  end

  describe "dedicated key vs. legacy secret_key_base precedence" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
      end)

      :ok
    end

    test "status/0 reports :dedicated when a dedicated key is configured, even with a legacy key present" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      assert Encryption.status() == :dedicated
    end

    test "a value encrypted under the dedicated key does not decrypt once only the legacy key resolves" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "under-dedicated-key"})

      # The dedicated key is removed WITHOUT rotating first — the legacy tier
      # takes over, and it must not accidentally read a value it never wrote.
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      assert Encryption.status() == :legacy_secret_key_base

      decrypted = Encryption.decrypt_fields(encrypted)
      refute Map.has_key?(decrypted, "api_key")
    end

    test "round-trips correctly while the dedicated key stays configured" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "a dedicated key shorter than the minimum length does not count as dedicated" do
      # Without a floor, a 1-character `integrations_encryption_key` reports
      # as the healthy `:dedicated` tier — false assurance. A too-short
      # dedicated key must fall through the same tier chain an absent one
      # would, not silently pass as "the real thing".
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "x")
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      assert Encryption.status() == :legacy_secret_key_base
    end

    test "warn_if_insecure/0 tells an operator with a too-short key apart from one who set nothing" do
      import ExUnit.CaptureLog

      Application.put_env(:phoenix_kit, :integrations_encryption_key, "too-short")
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      # Falls back to the legacy tier (same as an absent key would)...
      assert Encryption.status() == :legacy_secret_key_base

      log = capture_log(fn -> Encryption.warn_if_insecure() end)

      # ...but the operator who configured a key, just too short, must not
      # be told "no dedicated key is configured" — they configured one.
      assert log =~ "is shorter than"
      assert log =~ "IGNORED"
      refute log =~ "no dedicated key is"
    end
  end

  describe "status/0 and warn_if_insecure/0" do
    import ExUnit.CaptureLog

    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_enabled = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
        restore_env(:integration_encryption_enabled, original_enabled)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test ":disabled_explicit when integration_encryption_enabled is false, regardless of key availability" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "dedicated")
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert Encryption.status() == :disabled_explicit
    end

    test ":disabled_no_key when enabled but no key material resolves at all" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert Encryption.status() == :disabled_no_key
    end

    test ":disabled_no_key when the only configured key is too short and nothing else resolves" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "too-short")
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert Encryption.status() == :disabled_no_key

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "is shorter than"
      refute log =~ "no encryption key could be resolved"
    end

    test ":legacy_secret_key_base when only secret_key_base resolves" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy")

      assert Encryption.status() == :legacy_secret_key_base
    end

    test ":dedicated when a dedicated key is configured" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      assert Encryption.status() == :dedicated
    end

    test "warn_if_insecure/0 logs nothing for the healthy :dedicated case" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      log = capture_log(fn -> assert Encryption.warn_if_insecure() == :ok end)
      assert log == ""
    end

    test "warn_if_insecure/0 warns about the legacy fallback" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy")

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "secret_key_base"
    end

    test "warn_if_insecure/0 warns about plaintext storage when explicitly disabled" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "PLAINTEXT"
    end
  end

  describe "encrypt_fields_with_secret/2 (rotation primitive)" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      on_exit(fn -> restore_env(:integrations_encryption_key, original_dedicated) end)
      :ok
    end

    test "encrypts under an explicit secret, independent of the configured key" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)

      encrypted =
        Encryption.encrypt_fields_with_secret(
          %{"api_key" => "value"},
          "explicit-secret-well-over-min-length"
        )

      assert String.starts_with?(encrypted["api_key"], "enc:v1:")

      # Once that same secret becomes the configured dedicated key, it decrypts.
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "explicit-secret-well-over-min-length"
      )

      assert Encryption.decrypt_fields(encrypted)["api_key"] == "value"
    end

    test "a value encrypted with one explicit secret does not decrypt under another" do
      encrypted = Encryption.encrypt_fields_with_secret(%{"api_key" => "value"}, "secret-one")

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "secret-two-well-over-min-length"
      )

      refute Map.has_key?(Encryption.decrypt_fields(encrypted), "api_key")
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
