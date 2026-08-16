defmodule PhoenixKit.Integrations.Encryption do
  @moduledoc """
  AES-256-GCM encryption for sensitive integration credentials.

  Encrypts fields like `access_token`, `refresh_token`, `client_secret`,
  `api_key`, `bot_token`, `secret_key`, `password` before storing in the
  database. Decrypts them when reading.

  ## Key resolution

  The AES key is derived (SHA-256) from a secret, tried in this order:

    1. **Dedicated key** — `config :phoenix_kit, :integrations_encryption_key`.
       The recommended setup: a random secret independent of anything else
       in the app, generated with `mix phoenix_kit.integrations.rotate_key`
       and wired from an environment variable in `runtime.exs`, e.g.

           config :phoenix_kit,
             integrations_encryption_key: System.get_env("PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY")

    2. **Legacy fallback** — the application's `secret_key_base` (flat
       `config :phoenix_kit, :secret_key_base`, or the host app's own
       Endpoint secret). This is what every install used before the
       dedicated key existed, and it stays supported for backwards
       compatibility — but it means anyone who can read `secret_key_base`
       (env, config file, git history) can decrypt every stored integration
       credential, since that secret is shared with session signing, CSRF
       tokens, and everything else Phoenix derives from it. `status/0`
       reports this tier as `:legacy_secret_key_base` and
       `PhoenixKit.Supervisor` logs a boot warning about it — see
       `warn_if_insecure/0`.

  Set `config :phoenix_kit, integration_encryption_enabled: false` to turn
  encryption off entirely (new and existing writes store plaintext). This is
  reported as `:disabled_explicit` by `status/0` and is also warned about at
  boot — the setting takes effect silently, but its EFFECT is never silent.

  > #### Key rotation {: .warning}
  > Changing which secret produces the key — setting a dedicated key for the
  > first time, or rotating an existing one — makes every existing `enc:v1:`
  > value undecryptable under the new key. There is no dual-key fallback at
  > read time (that would silently mask a misconfigured key with plaintext
  > read failures, the opposite of the point). Use
  > `PhoenixKit.Integrations.KeyRotation.rotate/2` (or
  > `mix phoenix_kit.integrations.rotate_key`) to re-encrypt every stored
  > connection under the new secret BEFORE switching the app's config over
  > to it.
  """

  require Logger

  @sensitive_fields ~w(
    access_token refresh_token client_secret
    api_key bot_token secret_key password
  )

  # Prefix to identify encrypted values
  @encrypted_prefix "enc:v1:"

  @typedoc """
  Which secret currently backs the encryption key, from most to least secure:

    * `:dedicated` — a dedicated `:integrations_encryption_key` is set.
    * `:legacy_secret_key_base` — no dedicated key; falling back to a key
      derived from `secret_key_base`. Functional, but shares its secret
      with the rest of the app.
    * `:disabled_no_key` — encryption is enabled but no key material at all
      resolves (neither a dedicated key nor a usable `secret_key_base`).
      New writes store plaintext.
    * `:disabled_explicit` — `integration_encryption_enabled: false`. New
      writes store plaintext.
  """
  @type key_status :: :dedicated | :legacy_secret_key_base | :disabled_no_key | :disabled_explicit

  @doc """
  Returns the list of field keys that are encrypted.
  """
  @spec sensitive_fields() :: [String.t()]
  def sensitive_fields, do: @sensitive_fields

  @doc """
  Encrypt sensitive fields in an integration data map before saving.

  Non-sensitive fields and nil/empty values are left unchanged.
  Already-encrypted values (with `enc:v1:` prefix) are not re-encrypted.
  """
  @spec encrypt_fields(map()) :: map()
  def encrypt_fields(data) when is_map(data) do
    case encryption_key() do
      nil -> data
      key -> do_encrypt_fields(data, key)
    end
  end

  @doc """
  Decrypt sensitive fields in an integration data map after reading.

  Only values with the `enc:v1:` prefix are decrypted.
  Non-encrypted values are returned as-is for backwards compatibility.
  """
  @spec decrypt_fields(map()) :: map()
  def decrypt_fields(data) when is_map(data) do
    case encryption_key() do
      nil -> data
      key -> do_decrypt_fields(data, key)
    end
  end

  def decrypt_fields(other), do: other

  @doc """
  Check if encryption is available and enabled.

  True for both the `:dedicated` and `:legacy_secret_key_base` tiers — this
  answers "will values be encrypted at all", not "how well". Use `status/0`
  to distinguish the two.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    encryption_key() != nil
  end

  @doc """
  Reports which secret currently backs the encryption key. See `t:key_status/0`.

  Never raises, never touches the database — pure config/endpoint
  introspection, safe to call from a boot hook or a LiveView `mount/3`.
  """
  @spec status() :: key_status()
  def status do
    if encryption_enabled_flag?() do
      case resolve_tier() do
        {:dedicated, _secret} -> :dedicated
        {:legacy, _secret} -> :legacy_secret_key_base
        :none -> :disabled_no_key
      end
    else
      :disabled_explicit
    end
  end

  @doc """
  Logs a one-time warning when integration credentials are not protected by
  a dedicated key — called once at boot by `PhoenixKit.Supervisor`.
  Deliberately silent (no log line) for the healthy `:dedicated` case; the
  common, correctly-configured install must produce zero noise here.

  Never raises — returns `:ok` unconditionally.
  """
  @spec warn_if_insecure() :: :ok
  def warn_if_insecure do
    case status() do
      :dedicated ->
        :ok

      :legacy_secret_key_base ->
        Logger.warning(legacy_key_warning())

      :disabled_no_key ->
        Logger.warning(plaintext_warning("no encryption key could be resolved"))

      :disabled_explicit ->
        Logger.warning(plaintext_warning("integration_encryption_enabled is set to false"))
    end

    :ok
  end

  @doc """
  Encrypts sensitive fields using an EXPLICIT secret, bypassing the
  configured-key resolution entirely — the rotation primitive.

  `secret` is derived the same way a configured key would be
  (`derive_key/1`); this does not read `:integrations_encryption_key` or
  `secret_key_base`. Used by `PhoenixKit.Integrations.KeyRotation` to write
  values under a NEW secret before that secret becomes the active
  configured key — which is the whole point of rotation: the new key must
  be usable to encrypt before it's the one `encryption_key/0` resolves to.
  """
  @spec encrypt_fields_with_secret(map(), String.t()) :: map()
  def encrypt_fields_with_secret(data, secret)
      when is_map(data) and is_binary(secret) and secret != "" do
    do_encrypt_fields(data, derive_key(secret))
  end

  @doc """
  Whether `value` looks like an already-encrypted field value (carries the
  current `enc:v1:` prefix).

  Public so callers outside this module — `PhoenixKit.Integrations.KeyRotation`
  detecting which fields were encrypted before a rotation — don't hardcode
  the prefix literal themselves. A future `enc:v2:` format only needs to
  update this one place.
  """
  @spec encrypted?(term()) :: boolean()
  def encrypted?(value) when is_binary(value), do: String.starts_with?(value, @encrypted_prefix)
  def encrypted?(_value), do: false

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_encrypt_fields(data, key) do
    Enum.reduce(@sensitive_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          acc

        value when is_binary(value) ->
          if String.starts_with?(value, @encrypted_prefix) do
            # Already encrypted
            acc
          else
            Map.put(acc, field, encrypt_value(value, key))
          end

        _ ->
          acc
      end
    end)
  end

  defp do_decrypt_fields(data, key) do
    Enum.reduce(@sensitive_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) and value != "" ->
          maybe_decrypt_field(acc, field, value, key)

        _ ->
          acc
      end
    end)
  end

  defp maybe_decrypt_field(acc, field, value, key) do
    if String.starts_with?(value, @encrypted_prefix) do
      case decrypt_value(value, key) do
        {:ok, plaintext} ->
          Map.put(acc, field, plaintext)

        {:error, reason} ->
          # Returning `acc` unchanged here used to hand back the raw
          # `enc:v1:...` ciphertext as if it were the live credential —
          # silently, with no log line. Downstream code (bearer-token
          # resolution, "has credentials?" checks) has no idea that string
          # isn't a real secret, so a key change without running
          # `PhoenixKit.Integrations.KeyRotation.rotate/2` first produced a
          # garbled Authorization header instead of a loud, diagnosable
          # failure. Treat an undecryptable field as absent instead.
          Logger.error(
            "[Integrations.Encryption] Failed to decrypt field #{inspect(field)} " <>
              "(#{inspect(reason)}) — the active key does not match the one this value was " <>
              "encrypted under. Treating the credential as missing rather than returning " <>
              "ciphertext. If you just changed the encryption key/secret_key_base, run " <>
              "mix phoenix_kit.integrations.rotate_key first."
          )

          Map.delete(acc, field)
      end
    else
      acc
    end
  end

  defp encrypt_value(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    encoded = Base.encode64(iv <> tag <> ciphertext)
    @encrypted_prefix <> encoded
  end

  defp decrypt_value(@encrypted_prefix <> encoded, key) do
    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- binary do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp decrypt_value(_, _key), do: {:error, :not_encrypted}

  defp encryption_key do
    if encryption_enabled_flag?() do
      case resolve_tier() do
        {_tier, secret} -> derive_key(secret)
        :none -> nil
      end
    else
      nil
    end
  end

  defp encryption_enabled_flag? do
    Application.get_env(:phoenix_kit, :integration_encryption_enabled, true)
  end

  # `:dedicated` (an explicit `:integrations_encryption_key`) always wins over
  # `:legacy` (the secret_key_base-derived fallback) — a host that has set up
  # a dedicated key has already opted into the safer tier, and silently
  # preferring the legacy one for some values would leave part of the data
  # under the weaker key with no way to tell which.
  defp resolve_tier do
    case dedicated_key() do
      secret when is_binary(secret) and secret != "" ->
        {:dedicated, secret}

      _ ->
        case secret_key_base() do
          secret when is_binary(secret) and secret != "" -> {:legacy, secret}
          _ -> :none
        end
    end
  end

  defp dedicated_key do
    case PhoenixKit.Config.get(:integrations_encryption_key) do
      {:ok, secret} when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  # Flat `config :phoenix_kit, secret_key_base: ...` keeps precedence — it's
  # what an operator who deliberately set it expects to keep working. The
  # installer never stamps that key, though, so most host apps never set
  # it and encryption silently stayed disabled (secrets stored in
  # plaintext). Fall back to the host app's own Endpoint secret_key_base,
  # which every Phoenix app has — same discovery `Config.get_parent_endpoint/0`
  # already uses elsewhere (derived from `:parent_module`, which the
  # installer does set).
  defp secret_key_base do
    case PhoenixKit.Config.get(:secret_key_base) do
      {:ok, secret} when is_binary(secret) and secret != "" -> secret
      _ -> endpoint_secret_key_base()
    end
  end

  defp endpoint_secret_key_base do
    case PhoenixKit.Config.get_parent_endpoint() do
      {:ok, endpoint} -> endpoint.config(:secret_key_base)
      :error -> nil
    end
  rescue
    # The endpoint may be loaded but not started (early boot), or its
    # config table may not exist yet — either way, no key means no
    # encryption, not a crash.
    _ -> nil
  end

  defp derive_key(secret) do
    # Derive a dedicated 32-byte key for integration encryption
    :crypto.hash(:sha256, "phoenix_kit_integrations:" <> secret)
  end

  defp legacy_key_warning do
    "[PhoenixKit.Integrations] Integration credentials (API keys, OAuth tokens, bot tokens, " <>
      "etc.) are encrypted with a key derived from secret_key_base — no dedicated key is " <>
      "configured. secret_key_base is shared with session signing and CSRF tokens, and " <>
      "anyone who can read it (environment, a config file, git history) can decrypt every " <>
      "stored integration credential. Run `mix phoenix_kit.integrations.rotate_key` to " <>
      "generate a dedicated key and migrate existing connections to it, then configure " <>
      "integrations_encryption_key and restart."
  end

  defp plaintext_warning(why) do
    "[PhoenixKit.Integrations] Integration credentials (API keys, OAuth tokens, bot tokens, " <>
      "etc.) are being stored in PLAINTEXT (#{why}). Anyone with read access to the database " <>
      "can read every stored integration credential directly. If this is unintentional, set " <>
      "integration_encryption_enabled: true and configure integrations_encryption_key."
  end
end
