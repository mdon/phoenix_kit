# A store that fails its FIRST read and answers every one after it. Not
# contrived: `KeyStore.cached_read/0` deliberately memoises only successes, so a
# store on a mount that blips, or one being rewritten, behaves exactly like this
# — and every caller that re-reads gets a different answer than the one before.
defmodule PhoenixKit.Integrations.EncryptionTest.FlakyStore do
  @behaviour PhoenixKit.Integrations.KeyStore

  @secret "a-stored-secret-well-over-the-minimum"

  def secret, do: @secret

  @impl true
  def read(opts) do
    n = :counters.get(opts[:counter], 1)
    :counters.add(opts[:counter], 1, 1)

    if n == 0, do: {:error, {:flaky, "first read fails"}}, else: {:ok, @secret}
  end

  @impl true
  def write(_secret, _opts), do: :ok

  @impl true
  def preflight(_opts), do: :ok

  @impl true
  def describe(_opts), do: "/flaky/store.key"
end

defmodule PhoenixKit.Integrations.EncryptionTest do
  # async: false — the encryption_key/0 fallback tests mutate the global
  # `:phoenix_kit` app env (`:secret_key_base`, `:parent_module`), which
  # other concurrently-running async test files could observe mid-test.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyStore

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
      # be told "no dedicated key is configured" — they configured one. Asserts
      # the invariant rather than a phrase: the wording now comes from one
      # source (`Encryption.key_advice/0`) and is expected to be edited there.
      assert log =~ "shorter than"
      assert log =~ "rejected"
      assert log =~ "not the same as none being configured"
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
      assert log =~ "shorter than"
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

  describe "an unreadable key store is reported consistently" do
    # The per-read error and the boot warning are emitted by different functions
    # at different moments. They went out of step once already: the boot warning
    # was made tier-aware and the per-read error stayed blind, so a single run
    # could claim both "fell back to the secret_key_base key" and "no key at
    # all". They now share one source; these tests pin that they cannot diverge
    # again.
    setup do
      dir =
        Path.join(System.tmp_dir!(), "pk_store_consistency_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.key")
      File.write!(path, "")

      previous_store = Application.get_env(:phoenix_kit, :integrations_key_store)
      previous_skb = Application.get_env(:phoenix_kit, :secret_key_base)
      previous_parent = Application.get_env(:phoenix_kit, :parent_module)

      Application.put_env(
        :phoenix_kit,
        :integrations_key_store,
        {KeyStore.File, path: path}
      )

      on_exit(fn ->
        File.rm_rf(dir)

        restore = fn key, value ->
          if is_nil(value),
            do: Application.delete_env(:phoenix_kit, key),
            else: Application.put_env(:phoenix_kit, key, value)
        end

        restore.(:integrations_key_store, previous_store)
        restore.(:secret_key_base, previous_skb)
        restore.(:parent_module, previous_parent)
        KeyStore.invalidate_cache()
      end)

      # The per-read error is deliberately once-per-VM; clear the latch so each
      # test observes it. White-box on purpose — the alternative is a test that
      # silently passes because the message was already emitted.
      :persistent_term.erase({Encryption, :store_failure_logged})
      KeyStore.invalidate_cache()

      {:ok, path: path}
    end

    defp both_messages do
      import ExUnit.CaptureLog

      capture_log(fn ->
        Encryption.decrypt_fields(%{"api_key" => "enc:v1:not-real"})
        Encryption.warn_if_insecure()
      end)
    end

    test "with a legacy secret, both messages say a fallback happened" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("z", 64))

      log = both_messages()

      # Two surfaces, one run: the per-read error and the boot warning. Both
      # must describe the same reality — the assertion is about agreement, not
      # about a sentence, so unifying the wording cannot silently break it.
      assert log =~ "IS configured but its secret could not be read"
      assert log =~ "a key store is configured"
      assert log =~ "fell back to the secret_key_base-derived key"
      refute log =~ "PLAINTEXT"
    end

    test "with no key at all, both messages say PLAINTEXT and neither claims a fallback" do
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)

      log = both_messages()

      assert log =~ "IS configured but its secret could not be read"
      assert log =~ "a key store is configured"
      assert log =~ "PLAINTEXT"
      refute log =~ "fell back to the secret_key_base-derived key"
    end
  end

  describe "key_fingerprint/0 makes key reuse between sites visible" do
    setup do
      previous_skb = Application.get_env(:phoenix_kit, :secret_key_base)
      previous_key = Application.get_env(:phoenix_kit, :integrations_encryption_key)

      on_exit(fn ->
        restore = fn key, value ->
          if is_nil(value),
            do: Application.delete_env(:phoenix_kit, key),
            else: Application.put_env(:phoenix_kit, key, value)
        end

        restore.(:secret_key_base, previous_skb)
        restore.(:integrations_encryption_key, previous_key)
      end)

      :ok
    end

    # The whole point of part 2. derive_key/1 is a plain hash of the secret, so
    # two installs that share a secret_key_base — copied from a template, cloned
    # from a sibling environment — hold a byte-identical integration key. This
    # is what lets an operator SEE that.
    test "two installs with the same secret produce the same fingerprint" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, first} = Encryption.key_fingerprint()

      # Simulate the second site: same secret, resolved from scratch.
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, ^first} = Encryption.key_fingerprint()
    end

    test "a different secret produces a different fingerprint" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, first} = Encryption.key_fingerprint()

      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("t", 64))
      assert {:ok, second} = Encryption.key_fingerprint()

      refute first == second
    end

    # Discovered by writing this test with the opposite expectation. The key is
    # derived the same way whichever tier the secret came from, so copying your
    # secret_key_base into integrations_encryption_key does NOT change the key —
    # it only changes which config line it is read from. An operator doing that
    # believes they have migrated to a dedicated key; they have not, and every
    # site still sharing that secret_key_base still holds their key.
    #
    # The fingerprint says so out loud, which is the point of it.
    test "moving the SAME secret to the dedicated setting does not change the key" do
      secret = String.duplicate("u", 64)

      Application.put_env(:phoenix_kit, :secret_key_base, secret)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      assert {:ok, legacy} = Encryption.key_fingerprint()

      Application.put_env(:phoenix_kit, :integrations_encryption_key, secret)
      assert {:ok, dedicated} = Encryption.key_fingerprint()

      assert legacy == dedicated
    end

    test "the fingerprint is short, hex, and is not the key" do
      secret = String.duplicate("v", 64)
      Application.put_env(:phoenix_kit, :integrations_encryption_key, secret)

      assert {:ok, fingerprint} = Encryption.key_fingerprint()
      assert String.length(fingerprint) == 12
      assert fingerprint =~ ~r/\A[0-9a-f]{12}\z/
      refute fingerprint =~ secret
      refute secret =~ fingerprint
    end

    test "no key at all → :none, so nothing is displayed to compare" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)

      assert Encryption.key_fingerprint() == :none
    end
  end

  describe "key_diagnosis/0 is the one source both the warning and the doctor use" do
    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
      end)

      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("z", 64))
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :integrations_key_store)
      KeyStore.invalidate_cache()
      :ok
    end

    test "a real dedicated key is :ok" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, String.duplicate("k", 40))
      assert {:dedicated, :ok} = Encryption.key_diagnosis()
    end

    # What every one of our sites is in today.
    test "no dedicated key at all is :no_dedicated_key" do
      assert {:legacy_secret_key_base, :no_dedicated_key} = Encryption.key_diagnosis()
    end

    # Must outrank :no_dedicated_key: the advice attached to that one sends the
    # operator to rotate, which would move the data off a key the store may
    # still be holding.
    test "an unreadable store outranks 'no dedicated key'" do
      dir = Path.join(System.tmp_dir!(), "pk_diag_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.key")
      File.write!(path, "")
      on_exit(fn -> File.rm_rf(dir) end)

      Application.put_env(:phoenix_kit, :integrations_key_store, {KeyStore.File, path: path})
      KeyStore.invalidate_cache()

      assert {_status, :store_unreadable} = Encryption.key_diagnosis()
    end

    # "No dedicated key is configured" is a lie to someone who configured one.
    test "a configured-but-too-short key is :key_too_short, not 'none configured'" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "short")
      assert {_status, :key_too_short} = Encryption.key_diagnosis()
    end

    test "encryption switched off explicitly is :turned_off" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)
      assert {:disabled_explicit, :turned_off} = Encryption.key_diagnosis()
    end

    test "no key material at all is :no_key_material" do
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)
      assert {:disabled_no_key, :no_key_material} = Encryption.key_diagnosis()
    end
  end

  describe "key_signals/0 is one pass over the environment" do
    alias PhoenixKit.Integrations.EncryptionTest.FlakyStore

    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})
      end)

      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      KeyStore.invalidate_cache()
      :persistent_term.erase({Encryption, :store_failure_logged})
      :ok
    end

    # The defect this exists against, reproduced before the gather was made one
    # pass: the tier came from a failed read, the store state and the
    # fingerprint from a successful one, and the report printed the fingerprint
    # of the STORED key under the label "derived from secret_key_base". Two
    # operators comparing sites would have compared unlike keys while both pages
    # claimed the same tier — the exact failure the fingerprint exists to make
    # impossible.
    test "a store that answers one read and fails another cannot split the verdict" do
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
      KeyStore.invalidate_cache()

      signals = Encryption.key_signals()

      assert :counters.get(counter, 1) == 1,
             "key_signals/0 read the store #{:counters.get(counter, 1)} times; one gather, one read"

      # Whatever it decided, the parts of it agree.
      assert signals.fingerprint == expected_fingerprint(signals)
    end

    test "every signal in the map comes from the same reads, for either answer" do
      for first_read_fails? <- [true, false] do
        counter = :counters.new(1, [])
        # Burning the failing read first flips which answer the gather sees.
        unless first_read_fails?, do: :counters.add(counter, 1, 1)

        Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})

        signals = Encryption.key_signals()

        assert signals.fingerprint == expected_fingerprint(signals),
               "#{inspect(signals)}: the fingerprint is not the key the tier names"

        # A store answering with a usable secret IS a dedicated key source, so
        # the two cannot be seen apart within one gather.
        if match?({:holding, _}, signals.store) and not signals.too_short? do
          assert signals.tier == :dedicated,
                 "#{inspect(signals)}: a holding store beside a weaker tier"
        end
      end
    end

    # The fingerprint of the key the tier says is in use, derived independently
    # of the code under test.
    defp expected_fingerprint(%{enabled?: false}), do: :none
    defp expected_fingerprint(%{tier: :none}), do: :none

    defp expected_fingerprint(%{tier: tier}) do
      secret =
        case tier do
          :dedicated -> FlakyStore.secret()
          :legacy -> String.duplicate("s", 64)
        end

      key = :crypto.hash(:sha256, "phoenix_kit_integrations:" <> secret)

      digest =
        :sha256
        |> :crypto.pbkdf2_hmac(key, "phoenix_kit_integrations_fingerprint:v2", 100_000, 6)
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  describe "the states the real resolution actually produces" do
    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      dir = Path.join(System.tmp_dir!(), "pk_states_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    # Reachability is OBSERVED here, never argued. Two rounds running, a
    # hand-written rule about what the resolution can produce excluded a state
    # it produced daily — the rule and the code came from the same reasoning, so
    # the enumeration inherited the blind spot it existed to catch. This walks
    # real configurations through the real resolution and reports what comes
    # out; nothing here is entitled to an opinion about what should.
    test "walking real configurations, every state produced is consistent", %{dir: dir} do
      holding = Path.join(dir, "holding.key")
      File.write!(holding, String.duplicate("t", 40))
      File.chmod!(holding, 0o600)

      empty = Path.join(dir, "empty.key")
      File.write!(empty, "")
      File.chmod!(empty, 0o600)

      missing = Path.join(dir, "never-written.key")

      stores = [
        {"none", nil},
        {"holding", {KeyStore.File, path: holding}},
        {"unreadable", {KeyStore.File, path: empty}},
        {"no secret yet", {KeyStore.File, path: missing}}
      ]

      keys = [{"absent", nil}, {"short", "short"}, {"valid", String.duplicate("k", 40)}]
      bases = [{"present", String.duplicate("s", 64)}, {"absent", nil}]

      produced =
        for {_sn, store} <- stores, {_kn, key} <- keys, {_bn, base} <- bases do
          put(:integrations_key_store, store)
          put(:integrations_encryption_key, key)
          put(:secret_key_base, base)
          Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)
          KeyStore.invalidate_cache()

          signals = Encryption.key_signals()

          # Every produced state renders, and the report agrees with it.
          report = Encryption.key_report(signals)
          assert is_binary(report.summary) and report.summary != ""

          if signals.tier == :none do
            assert signals.fingerprint == :none
            refute report.rotation_safe?
          end

          if match?({:holding, _}, signals.store) and not signals.too_short? do
            assert signals.tier == :dedicated,
                   "#{inspect(signals)}: a store holding a usable secret beside a weaker tier"
          end

          {signals.tier, signals.too_short?, store_tag(signals.store)}
        end
        |> Enum.uniq()

      # The collapse this catches: a configured store with nothing in it read as
      # `:not_configured` and was reported as `{:holding, _}` — "your key is
      # saved here" about a file that does not exist. `KeyStore.read/0`'s own
      # doc forbids collapsing those two, and the tests enumerated a
      # `:no_secret_yet` signal production could never emit.
      assert {:legacy, false, :no_secret_yet} in produced,
             "the real resolution never produced :no_secret_yet: #{inspect(produced)}"

      assert {:dedicated, false, :holding} in produced
      assert {:legacy, false, :unreadable} in produced
      assert {:none, false, :absent} in produced
    end

    defp store_tag(:absent), do: :absent
    defp store_tag({tag, _location}), do: tag

    defp put(key, nil), do: Application.delete_env(:phoenix_kit, key)
    defp put(key, value), do: Application.put_env(:phoenix_kit, key, value)
  end
end
