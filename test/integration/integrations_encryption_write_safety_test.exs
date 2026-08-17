defmodule PhoenixKit.Integration.IntegrationsEncryptionWriteSafetyTest do
  @moduledoc """
  Proves that a sensitive field which fails to decrypt under the currently
  active key survives a SUBSEQUENT write instead of being permanently
  erased — the write-side counterpart to
  `PhoenixKit.Integrations.EncryptionTest`'s "decrypt failure safety"
  describe block, which only proves the READ side (the field is dropped,
  never handed back as raw ciphertext) and stops before the write that
  used to make the loss irreversible.

  ## Why this matters

  `PhoenixKit.Integrations.Encryption.decrypt_fields/1` drops a field that
  fails to decrypt — correct, since a caller must never mistake stale
  ciphertext for a real credential. But `PhoenixKit.Integrations.resolve_uuid/2`
  hands that same (now-missing-a-field) map to every write path as the
  merge base for what gets saved, and `save_integration/2` writes
  `value_json` WHOLESALE. Without a write-side safeguard, a field merely
  absent because it couldn't be decrypted right now — not because any
  caller meant to remove it — would be permanently deleted by the very
  next write to the row, including fully automatic, credential-blind ones
  like `record_validation/3` (driven by `record_refresh_failure/2` and
  `maybe_record_recovery/1` on every OAuth token-refresh attempt, with no
  operator involved). This is exactly the window a real key rotation opens
  between "rotation finished" and "app restarted onto the new key" — see
  `PhoenixKit.Integrations.KeyRotation`'s moduledoc.

  `async: false` — mutates the global `:phoenix_kit` Application env
  (`:secret_key_base`), same reasoning as
  `PhoenixKit.Integration.KeyRotationTest` and
  `PhoenixKit.Integrations.EncryptionTest`.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Settings.Queries

  setup do
    original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

    on_exit(fn ->
      restore_env(:integrations_encryption_key, original_dedicated)
      restore_env(:secret_key_base, original_flat)
    end)

    Application.delete_env(:phoenix_kit, :integrations_encryption_key)
    Application.put_env(:phoenix_kit, :secret_key_base, "key-A-write-safety-test")

    :ok
  end

  defp raw_value_json(uuid), do: Queries.get_setting_by_uuid(uuid).value_json

  describe "a field that fails to decrypt survives a write it is not part of" do
    test "record_validation (status/timestamp only) does not erase a sibling field that can't decrypt" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-live-real-secret"})

      before_key_change = raw_value_json(uuid)
      assert String.starts_with?(before_key_change["api_key"], "enc:v1:")

      # Simulate the key changing without running the rotation task first —
      # e.g. the window between a real rotation finishing and the app
      # restarting onto the new key, or an operator changing secret_key_base
      # by hand.
      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      # A fully automatic write that never references api_key at all.
      :ok = Integrations.record_validation(uuid, {:error, "network blip"})

      after_write = raw_value_json(uuid)

      assert after_write["api_key"] == before_key_change["api_key"],
             "the undecryptable field's stored ciphertext must survive an unrelated write untouched"

      # Reversibility: switching back to the original key must still
      # decrypt it — the whole point of the fix.
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-write-safety-test")
      assert Encryption.decrypt_fields(after_write)["api_key"] == "sk-live-real-secret"
    end

    test "save_setup with attrs that don't reference the undecryptable field does not erase it" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      # `attrs` is empty — save_setup still merges onto the (now
      # api_key-less) decrypted snapshot and writes `value_json` wholesale,
      # exactly like a real "Test Connection" re-save would.
      {:ok, saved} = Integrations.save_setup(uuid, %{})
      assert saved["provider"] == "openrouter"
      refute Map.has_key?(saved, "api_key")

      after_write = raw_value_json(uuid)
      assert String.starts_with?(after_write["api_key"], "enc:v1:")

      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-write-safety-test")
      assert Encryption.decrypt_fields(after_write)["api_key"] == "sk-live-real-secret"
    end

    test "rename_connection does not erase an undecryptable field" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      {:ok, _} = Integrations.rename_connection(uuid, "a new name")

      after_write = raw_value_json(uuid)
      assert String.starts_with?(after_write["api_key"], "enc:v1:")

      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-write-safety-test")
      assert Encryption.decrypt_fields(after_write)["api_key"] == "sk-live-real-secret"
    end
  end

  describe "a field a caller genuinely means to remove stays removed" do
    test "disconnect still clears an undecryptable field instead of restoring it" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-live-real-secret"})

      # api_key becomes unreadable under the (now) active key. disconnect/3
      # deliberately does not call `carry_forward_undecryptable/3` — its
      # `Map.take`-based allowlist already expresses the caller's intent
      # unambiguously (drop everything not listed), and the write-survival
      # fix must not second-guess that by resurrecting a field disconnect
      # meant to remove just because it also happens to be undecryptable
      # right now.
      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      :ok = Integrations.disconnect(uuid)

      raw = raw_value_json(uuid)
      refute Map.has_key?(raw, "api_key")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)
end
