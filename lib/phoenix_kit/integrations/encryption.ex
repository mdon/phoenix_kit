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
  >
  > A field that's temporarily undecryptable (mismatched key, mid-rotation)
  > is never permanently lost by an unrelated write in the meantime — see
  > `decrypt_fields_with_failures/1` and
  > `PhoenixKit.Integrations.save_setup/4`'s write path. The stored
  > ciphertext survives untouched until the correct key is active again.
  """

  require Logger

  alias PhoenixKit.Integrations.KeyStore

  # A dedicated key this short provides essentially no assurance over the
  # legacy fallback it's meant to replace — without a floor, a 1-character
  # `:integrations_encryption_key` reports as the healthy `:dedicated` tier
  # (banner hidden, no boot warning) just as confidently as a real random
  # secret would. Not an attempt at full entropy validation, just a floor
  # against the comically weak end.
  @min_dedicated_key_length 20

  # Fixed, ecosystem-wide: a per-install salt would give two installs holding the
  # same key different fingerprints, which is the one thing this must never do.
  @fingerprint_domain "phoenix_kit_integrations_fingerprint:v2"

  # Only raises the price of each guess; it cannot make a weak secret strong.
  # Costs roughly a tenth of a second, paid on an admin page mount and in a mix
  # task, neither of which is a hot path.
  @fingerprint_iterations 100_000

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
  Same as `decrypt_fields/1`, but also returns the names of any fields that
  looked encrypted (carried the `enc:v1:` prefix) yet failed to decrypt
  under the currently active key.

  `decrypt_fields/1` drops an undecryptable field entirely — correct for
  every caller that treats the result as a live credential to use or
  display, since a caller must never mistake stale ciphertext for a real
  value. But `PhoenixKit.Integrations.resolve_uuid/2` also hands this same
  map to write paths that merge new attributes onto it and save the result
  wholesale: for THOSE callers, "absent because it failed to decrypt" and
  "absent because nothing was ever there" are not the same thing — the
  first must not be permanently erased by an unrelated write. The returned
  field-name list lets a write path restore an untouched field's original
  ciphertext from storage (see `PhoenixKit.Integrations.save_setup/4`,
  `refresh_access_token/1`, `exchange_code/4`, `record_validation/3`)
  without ever exposing that ciphertext as if it were usable.
  """
  @spec decrypt_fields_with_failures(map()) :: {map(), [String.t()]}
  def decrypt_fields_with_failures(data) when is_map(data) do
    case encryption_key() do
      nil -> {data, []}
      key -> do_decrypt_fields_tracking(data, key)
    end
  end

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
  Encrypt a single value, for callers with a bare field to protect rather
  than a full `encrypt_fields/1`-shaped map (e.g. an Ecto schema field like
  `PhoenixKit.Modules.Storage.Bucket.secret_access_key`).

  Same cipher, key derivation and `enc:v1:` prefix as `encrypt_fields/1`.
  Nil/empty and already-encrypted values (see `encrypted?/1`) pass through
  unchanged. When encryption is unavailable (no `secret_key_base`), the
  value is stored as plaintext — same as `encrypt_fields/1` — but this
  path logs a warning, since a caller that reaches for single-value
  encryption is usually protecting something as sensitive as the fields
  `encrypt_fields/1` already covers, and a schema field silently staying
  plaintext is exactly the gap this API exists to close.
  """
  @spec encrypt_value(String.t() | nil) :: String.t() | nil
  def encrypt_value(nil), do: nil
  def encrypt_value(""), do: ""

  def encrypt_value(value) when is_binary(value) do
    if encrypted?(value) do
      value
    else
      case encryption_key() do
        nil ->
          Logger.warning(
            "PhoenixKit.Integrations.Encryption.encrypt_value/1: no encryption key available " <>
              "(secret_key_base not configured) — storing value as plaintext"
          )

          value

        key ->
          encrypt_value(value, key)
      end
    end
  end

  @doc """
  Decrypt a value produced by `encrypt_value/1`.

  Returns `{:ok, plaintext}`. A value without the `enc:v1:` prefix is
  returned as `{:ok, value}` unchanged — backwards compatibility with
  data written before encryption was applied. `{:error, :encryption_unavailable}`
  when the value IS prefixed but no encryption key is available (no
  `secret_key_base`) — unlike the nil-key path in `encrypt_value/1`, there
  is no plaintext to fall back to here, only ciphertext nobody can read
  right now. `{:error, reason}` for any other decrypt failure (wrong/rotated
  key, corrupted ciphertext).
  """
  @spec decrypt_value(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def decrypt_value(nil), do: {:ok, nil}
  def decrypt_value(""), do: {:ok, ""}

  def decrypt_value(value) when is_binary(value) do
    if encrypted?(value) do
      case encryption_key() do
        nil -> {:error, :encryption_unavailable}
        key -> decrypt_value(value, key)
      end
    else
      {:ok, value}
    end
  end

  @doc """
  Reports which secret currently backs the encryption key. See `t:key_status/0`.

  Never touches the database, and safe to call from a boot hook or a LiveView
  `mount/3`. It is no longer pure config introspection: when a key store is
  configured it may read from it (memoised after the first success). A
  host-supplied store cannot crash this call — `PhoenixKit.Integrations.KeyStore`
  turns a raising store into an error tuple.
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

  @typedoc """
  The active tier plus **why** it is that tier.

  Exists because two places give advice about the same situation —
  `warn_if_insecure/0` and `mix phoenix_kit.doctor` — and advice that is correct
  for one reason is actively harmful for another. Telling an operator whose key
  store is unreadable to run `mix phoenix_kit.integrations.rotate_key` would
  rotate away from a key their data may still be encrypted under. Telling
  someone who *did* configure a key that none is configured is simply false.

  Both callers branch on this one value, so they cannot drift apart.
  """
  @type key_diagnosis ::
          {:dedicated, :ok | :store_unreadable}
          | {:legacy_secret_key_base, :store_unreadable | :key_too_short | :no_dedicated_key}
          | {:disabled_no_key, :store_unreadable | :key_too_short | :no_key_material}
          | {:disabled_explicit, :turned_off}

  @doc """
  The active tier and the reason for it. See `t:key_diagnosis/0`.

  The reasons are ordered by what must be acted on first: an unreadable key
  store outranks "no dedicated key", because repairing the store may restore the
  very key the data is encrypted under, while rotating would abandon it.
  """
  @spec key_diagnosis() :: key_diagnosis()
  def key_diagnosis, do: key_report().diagnosis

  @typedoc """
  The raw signals the key state is made of, gathered in one pass.

  Deliberately separate from the verdict below. Everything that decides what an
  operator should be told is read here, once, and then the verdict is a function
  of this map alone — it consults nothing further. Three rounds of fixes each
  produced a message contradicting itself because a later step went back to the
  environment for one more fact and got a different answer than the step before.
  """
  @type key_signals :: %{
          enabled?: boolean(),
          tier: :dedicated | :legacy | :none,
          too_short?: boolean(),
          store: :absent | {:unreadable, String.t()} | {:holding, String.t()},
          fingerprint: :none | {:ok, String.t()}
        }

  @typedoc """
  Everything a surface needs to say about the key state, decided together.

  One clause of `key_report/1` produces a whole one of these. There is no path
  by which its parts can disagree: the fingerprint and the tier that produced it
  are a single term, and `:key_store` is `nil` unless a store is actually
  configured.
  """
  @type key_report :: %{
          diagnosis: key_diagnosis(),
          severity: :ok | :warn | :fail,
          summary: String.t(),
          consequence: String.t(),
          action: String.t(),
          rotation_safe?: boolean(),
          fingerprint: :none | {:ok, String.t(), String.t()},
          key_store: String.t() | nil
        }

  @doc """
  Reads every signal the key verdict depends on, in one pass.
  """
  @spec key_signals() :: key_signals()
  def key_signals do
    %{
      enabled?: encryption_enabled_flag?(),
      tier: raw_tier(),
      too_short?: dedicated_key_too_short?(),
      store: store_state(),
      fingerprint: key_fingerprint()
    }
  end

  defp raw_tier do
    case resolve_tier() do
      {:dedicated, _secret} -> :dedicated
      {:legacy, _secret} -> :legacy
      :none -> :none
    end
  end

  # "No store configured" and "a store is configured but cannot be read" call
  # for opposite advice — set one up, versus repair this one and write nothing
  # meanwhile — so they are distinct signals rather than one absence.
  defp store_state do
    case {KeyStore.configured?(), KeyStore.cached_read()} do
      {false, _} -> :absent
      {true, {:error, _}} -> {:unreadable, KeyStore.describe() || "the configured key store"}
      {true, _} -> {:holding, KeyStore.describe() || "the configured key store"}
    end
  end

  @doc """
  The complete report for the current state.
  """
  @spec key_report() :: key_report()
  def key_report, do: key_report(key_signals())

  @doc """
  The verdict for a set of signals — one ordered clause per reachable state.

  Public because the acceptance criterion here is an enumeration: every
  reachable combination rendered whole and read for self-contradiction. That
  needs a seam that takes the state rather than discovering it.

  Clause order is the priority an operator should act in. An unreadable store
  outranks everything below it: repairing it may restore the very key the data
  is encrypted under, while the advice attached to the lower clauses would send
  them away from it.
  """
  @spec key_report(key_signals()) :: key_report()

  # Turned off deliberately. Nothing below matters — a short key or an unread
  # store is irrelevant when no encryption is being attempted.
  def key_report(%{enabled?: false} = signals) do
    report(signals, {:disabled_explicit, :turned_off}, :warn,
      summary: "encryption is switched off (integration_encryption_enabled: false)",
      consequence:
        "integration credentials are being written in PLAINTEXT, readable by anyone with " <>
          "read access to the database",
      action: "If that is unintentional, set integration_encryption_enabled: true",
      rotation_safe?: false,
      tier_label: nil
    )
  end

  # A key configured explicitly wins over the store (`configured_dedicated_key/0`
  # reads config first and never consults the store when it finds one), so a
  # broken store does NOT mean a broken tier. Ordered above the store clauses
  # because it was ordered below them, and that produced "encryption fell back
  # to secret_key_base" — plus a warning banner and a FALLBACK label on the
  # fingerprint — while a perfectly good dedicated key was doing the work.
  # Reproduced before fixing: a valid key in config with an unreadable store
  # reported `{:legacy_secret_key_base, :store_unreadable}`.
  def key_report(%{tier: :dedicated, store: {:unreadable, location}} = signals) do
    report(signals, {:dedicated, :store_unreadable}, :warn,
      summary:
        "a dedicated encryption key is in use, but the configured key store could not be read",
      consequence:
        "encryption itself is fine — the key in use comes from configuration. What is broken " <>
          "is the spare copy: nothing is backing that key up, and the next rotation will " <>
          "refuse at its pre-flight",
      action:
        "Repair the store at #{location}; until it reads back, assume the key is saved nowhere",
      rotation_safe?: false,
      tier_label: "dedicated key"
    )
  end

  def key_report(%{store: {:unreadable, location}, tier: :none} = signals) do
    report(signals, {:disabled_no_key, :store_unreadable}, :fail,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action: repair_store_action(),
      rotation_safe?: false,
      tier_label: nil
    )
  end

  def key_report(%{store: {:unreadable, location}} = signals) do
    report(signals, {:legacy_secret_key_base, :store_unreadable}, :warn,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence: fallback_consequence(),
      action: repair_store_action(),
      rotation_safe?: false,
      tier_label: "FALLBACK key — the configured key store could not be read"
    )
  end

  def key_report(%{too_short?: true, tier: :none} = signals) do
    report(signals, {:disabled_no_key, :key_too_short}, :fail,
      summary: too_short_summary(),
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action: replace_key_action(),
      rotation_safe?: true,
      tier_label: nil
    )
  end

  def key_report(%{too_short?: true} = signals) do
    report(signals, {:legacy_secret_key_base, :key_too_short}, :warn,
      summary: too_short_summary(),
      consequence: fallback_consequence(),
      action: replace_key_action(),
      rotation_safe?: true,
      tier_label: "FALLBACK key — the configured key was rejected as too short"
    )
  end

  # `{tier: :dedicated, too_short?: true}` is unreachable and has no clause: a
  # key rejected for being short is precisely one that did not make the
  # dedicated tier, so resolution would have returned something else.
  def key_report(%{tier: :dedicated} = signals) do
    report(signals, {:dedicated, :ok}, :ok,
      summary: "a dedicated encryption key is in use",
      consequence: "",
      action: "",
      rotation_safe?: true,
      tier_label: "dedicated key"
    )
  end

  def key_report(%{tier: :legacy} = signals) do
    report(signals, {:legacy_secret_key_base, :no_dedicated_key}, :warn,
      summary: "integration credentials are encrypted with a key DERIVED from secret_key_base",
      consequence:
        "secret_key_base is shared with session signing and CSRF tokens, so anyone who can " <>
          "read it (environment, a config file, git history) can decrypt every stored " <>
          "credential — and any other site sharing that secret_key_base holds the same key",
      action:
        "Run `mix phoenix_kit.integrations.rotate_key` for a key of this site's own, then " <>
          "restart",
      rotation_safe?: true,
      tier_label: "derived from secret_key_base"
    )
  end

  def key_report(%{tier: :none} = signals) do
    report(signals, {:disabled_no_key, :no_key_material}, :fail,
      summary: "no encryption key resolves at all",
      consequence:
        "integration credentials (API keys, OAuth tokens, bot tokens) are being written in " <>
          "PLAINTEXT, readable by anyone with read access to the database",
      action: no_key_action(signals.store),
      rotation_safe?: false,
      tier_label: nil
    )
  end

  # Assembles the report so that no clause can forget a field or pair a
  # fingerprint with a label from a different state: the label arrives with the
  # verdict, and the value with the signals, and they are joined here once.
  defp report(signals, diagnosis, severity, fields) do
    %{
      diagnosis: diagnosis,
      severity: severity,
      summary: Keyword.fetch!(fields, :summary),
      consequence: Keyword.fetch!(fields, :consequence),
      action: Keyword.fetch!(fields, :action),
      rotation_safe?: Keyword.fetch!(fields, :rotation_safe?),
      fingerprint: label_fingerprint(signals.fingerprint, Keyword.fetch!(fields, :tier_label)),
      key_store: store_location(signals.store)
    }
  end

  defp label_fingerprint(:none, _label), do: :none
  defp label_fingerprint({:ok, _value}, nil), do: :none
  defp label_fingerprint({:ok, value}, label), do: {:ok, value, label}

  defp store_location(:absent), do: nil
  defp store_location({_state, location}), do: location

  defp fallback_consequence,
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"

  defp repair_store_action,
    do:
      "Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key " <>
        "may still be the one your data is encrypted under. Repair the store first; " <>
        "repairing it later will NOT make anything written in the meantime readable"

  defp too_short_summary,
    do:
      "a dedicated key IS configured but was rejected as shorter than " <>
        "#{@min_dedicated_key_length} characters, which is not the same as none being " <>
        "configured"

  defp replace_key_action,
    do:
      "Replace it with a real secret — `mix phoenix_kit.integrations.rotate_key` generates " <>
        "one, and stores it for you if a key store is configured"

  # The two absences the reviewer asked to keep apart: nothing configured at all
  # versus a store that is configured and empty. Set one up, versus put a secret
  # into the one you have.
  defp no_key_action(:absent),
    do: "Configure integrations_encryption_key, or a key store, and restart"

  # NOT "run rotate_key": rotation refuses outright while no key is active
  # (`KeyRotation.rotate/2` returns `{:error, {:encryption_disabled, _}}`), so
  # that advice would send an operator to a command that cannot help them. The
  # store being configured and empty is still worth saying — it is the
  # difference between "set one up" and "you have one, it is just empty".
  defp no_key_action({:no_secret_yet, location}),
    do:
      "A key store is configured at #{location} but holds no secret yet. Set " <>
        "integrations_encryption_key and restart; rotation cannot help while no key is active"

  defp no_key_action({_state, location}),
    do: "Check the key store at #{location}, then restart"

  @doc """
  The report rendered as one sentence, for a log line.

  Never includes the fingerprint: a log's readership is wider than the admin
  page's, and the fingerprint is a verifier against candidate secrets.
  """
  @spec key_report_message(key_report()) :: String.t()
  def key_report_message(report) do
    [report.summary, report.consequence, report.action]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(". ")
  end

  @doc """
  A short, non-reversible fingerprint of the key currently in use, or `:none`.

  Exists so that **key reuse between sites is visible**. `derive_key/1` is a
  plain SHA-256 over the secret, so two installs that share a `secret_key_base`
  — copied from a template, cloned from a sibling environment, inherited with a
  `config/dev.exs` — derive a byte-identical integration key and neither has any
  way to notice. One compromise then exposes every site that shares it.

  Two installs showing the same fingerprint are using the same key.

  ## Comparing two numbers only means something like-for-like

  Three things make one site show a fingerprint that is not "its" key, and none
  of them are visible in the number itself, so **always read the tier printed
  next to it**:

    * an unreadable key store, so the fallback key is being fingerprinted;
    * a dedicated key rejected as too short, same effect;
    * encryption disabled, in which case there is no fingerprint at all.

  There is also an environment trap. `mix phoenix_kit.doctor` resolves the key
  in the **task's** environment; a key delivered by an env var read in
  `runtime.exs` may differ from what the running server holds. A task and an
  admin page on the same site can therefore disagree. Compare admin page with
  admin page, or task with task.

  ## What it gives away

  Domain-separated from `derive_key/1` and truncated, so it is not the key and
  cannot be turned back into one. It IS a verifier: anyone holding it can test
  candidate secrets offline.

  There is no salt, and there cannot be one — a per-install salt would make two
  installs with the same key show different numbers, destroying the only thing
  this is for. What can be raised is the cost per guess, so the digest is
  iterated (PBKDF2-HMAC-SHA256, #{@fingerprint_iterations} iterations) instead
  of the two plain hashes it used to be. The prefix is global to PhoenixKit, so
  a table over common `secret_key_base` values works against every install at
  once; iteration makes building that table that many times more expensive, and
  nothing more. **The fingerprint is no stronger than the secret behind it** —
  against a weak, guessable secret it is a verification oracle, which is exactly
  the situation this feature exists to surface.

  Accordingly it is shown on the admin-only system page, and by
  `mix phoenix_kit.doctor` only when explicitly asked for: a task's output ends
  up in CI logs, whose readership is wider than the page's.
  """
  @spec key_fingerprint() :: {:ok, String.t()} | :none
  def key_fingerprint do
    case encryption_key() do
      key when is_binary(key) ->
        {:ok,
         :sha256
         |> :crypto.pbkdf2_hmac(key, @fingerprint_domain, @fingerprint_iterations, 6)
         |> Base.encode16(case: :lower)}

      _ ->
        :none
    end
  end

  @doc """
  Shortest secret accepted as a dedicated key.

  Public so `mix phoenix_kit.integrations.rotate_key` can refuse a `--new-key`
  this module would later reject: without the check the rotation "succeeds",
  the data is re-encrypted, and the app silently drops to a weaker tier on the
  next restart.
  """
  @spec min_dedicated_key_length() :: pos_integer()
  def min_dedicated_key_length, do: @min_dedicated_key_length

  @doc """
  Logs a one-time warning when integration credentials are not protected by
  a dedicated key — called once at boot by `PhoenixKit.boot/1`.
  Deliberately silent (no log line) for the healthy `:dedicated` case; the
  common, correctly-configured install must produce zero noise here.

  An `:integrations_encryption_key` shorter than the minimum length gets
  its OWN message rather than being folded into the "no dedicated key"
  wording below — an operator who set one, just too short, needs
  different advice than one who never set it, and telling them "no
  dedicated key is configured" when they configured one is simply false.

  Never raises — returns `:ok` unconditionally.
  """
  @spec warn_if_insecure() :: :ok
  def warn_if_insecure do
    report = key_report()

    case report.severity do
      :ok -> :ok
      :fail -> Logger.error("[PhoenixKit.Integrations] " <> key_report_message(report))
      :warn -> Logger.warning("[PhoenixKit.Integrations] " <> key_report_message(report))
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

  Used to keep `encrypt_value/1` idempotent (never double-encrypt) and to
  let callers tell an already-migrated field apart from legacy plaintext.
  Also public so callers outside this module —
  `PhoenixKit.Integrations.KeyRotation` detecting which fields were
  encrypted before a rotation — don't hardcode the prefix literal
  themselves. A future `enc:v2:` format only needs to update this one
  place.
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
    {result, _failed_fields} = do_decrypt_fields_tracking(data, key)
    result
  end

  defp do_decrypt_fields_tracking(data, key) do
    Enum.reduce(@sensitive_fields, {data, []}, fn field, {acc, failed_fields} ->
      case Map.get(acc, field) do
        value when is_binary(value) and value != "" ->
          case maybe_decrypt_field(acc, field, value, key) do
            {:ok, new_acc} -> {new_acc, failed_fields}
            {:failed, new_acc} -> {new_acc, [field | failed_fields]}
          end

        _ ->
          {acc, failed_fields}
      end
    end)
  end

  defp maybe_decrypt_field(acc, field, value, key) do
    if String.starts_with?(value, @encrypted_prefix) do
      case decrypt_value(value, key) do
        {:ok, plaintext} ->
          {:ok, Map.put(acc, field, plaintext)}

        {:error, reason} ->
          # Returning `acc` unchanged here used to hand back the raw
          # `enc:v1:...` ciphertext as if it were the live credential —
          # silently, with no log line. Downstream code (bearer-token
          # resolution, "has credentials?" checks) has no idea that string
          # isn't a real secret, so a key change without running
          # `PhoenixKit.Integrations.KeyRotation.rotate/2` first produced a
          # garbled Authorization header instead of a loud, diagnosable
          # failure. Treat an undecryptable field as absent instead — the
          # `:failed` tag lets `decrypt_fields_with_failures/1` tell a write
          # path this field is absent ONLY because it can't be read right
          # now, not because it was never there.
          Logger.error(
            "[Integrations.Encryption] Failed to decrypt field #{inspect(field)} " <>
              "(#{inspect(reason)}) — the active key does not match the one this value was " <>
              "encrypted under. Treating the credential as missing rather than returning " <>
              "ciphertext. If you just changed the encryption key/secret_key_base, run " <>
              "mix phoenix_kit.integrations.rotate_key first."
          )

          {:failed, Map.delete(acc, field)}
      end
    else
      {:ok, acc}
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
    case configured_dedicated_key() do
      {:ok, secret} -> secret
      _ -> nil
    end
  end

  # Whether an `:integrations_encryption_key` IS configured (non-blank) but
  # rejected for being shorter than `@min_dedicated_key_length` — distinct
  # from simply not having one set at all. `warn_if_insecure/0` uses this to
  # give an operator who configured a weak key different advice than one
  # who never configured one.
  @spec dedicated_key_too_short?() :: boolean()
  defp dedicated_key_too_short? do
    match?(:too_short, configured_dedicated_key())
  end

  defp configured_dedicated_key do
    case PhoenixKit.Config.get(:integrations_encryption_key) do
      {:ok, secret} when is_binary(secret) and secret != "" ->
        check_dedicated_length(secret)

      _ ->
        stored_dedicated_key()
    end
  end

  # A secret persisted by `PhoenixKit.Integrations.KeyStore` counts as the same
  # `:dedicated` tier — it is a dedicated key, just one the operator did not
  # have to paste into config by hand after rotating. Explicit configuration
  # still wins: someone who set `:integrations_encryption_key` deliberately
  # must not have it quietly overridden by a file.
  #
  # Read through the memoised path: this runs once per encrypted field, and an
  # unmemoised read would open a file every time.
  defp stored_dedicated_key do
    case KeyStore.cached_read() do
      {:ok, secret} when is_binary(secret) and secret != "" ->
        check_dedicated_length(secret)

      :not_configured ->
        :unset

      # A configured store that cannot be READ is not the same as no store, and
      # collapsing the two here is how a fleet quietly splits in half: the app
      # falls through to the weaker `:legacy` tier, old values stop decrypting,
      # and NEW values get written under the legacy key. Fixing the file later
      # then leaves those new rows unreadable forever. The fallback is kept —
      # refusing outright would resolve to no key at all, and a nil key makes
      # writes store plaintext, which is worse — but it is never silent.
      {:error, reason} ->
        log_store_failure_once(reason)
        :unset
    end
  end

  # Encryption runs once per credential field and read failures are deliberately
  # not cached, so this would otherwise repeat per field, per request. One line
  # per VM is enough to be found.
  defp log_store_failure_once(reason) do
    key = {__MODULE__, :store_failure_logged}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.error(
        "[PhoenixKit.Integrations] A key store IS configured but its secret could not be " <>
          "read (#{KeyStore.describe_error(reason)}): #{weaker_tier_consequence_from_env()}. " <>
          "Repairing the store later will not make anything written in the meantime readable. " <>
          "Fix the store before writing anything else."
      )
    end

    :ok
  end

  defp check_dedicated_length(secret) do
    if String.length(secret) >= @min_dedicated_key_length,
      do: {:ok, secret},
      else: :too_short
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

  # ONE source for what falling off the dedicated tier actually costs, shared by
  # every surface that reports it. They used to phrase it separately, and the
  # per-read one stayed tier-blind after the boot one was fixed — so a single
  # run could emit two messages that contradicted each other about whether a
  # fallback key even existed. Deriving it in one place is what stops that
  # recurring.
  #
  # Reads `secret_key_base/0` rather than `status/0`: status resolves the tier,
  # which consults the store, which is what called this — that would recurse.
  # Derived from the status being described, NOT from a fresh look at the
  # environment. Reading the environment again is what produced the third
  # instance of this defect: a report built for the legacy tier asked the
  # environment, got a different answer, and announced "NO key resolved at all"
  # directly above a fingerprint of the key that had in fact resolved. A value
  # rendered from a state must not consult anything outside that state.
  defp weaker_tier_consequence(:disabled_no_key),
    do: "NO key resolved at all — integration credentials are being written in PLAINTEXT"

  defp weaker_tier_consequence(_status),
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"

  # The one caller that genuinely cannot be handed a status: it runs DURING tier
  # resolution, so asking for one would recurse. It infers the same two cases
  # from the secret it can read without touching the store, and routes through
  # the same wording above.
  defp weaker_tier_consequence_from_env do
    case secret_key_base() do
      secret when is_binary(secret) and secret != "" ->
        weaker_tier_consequence(:legacy_secret_key_base)

      _ ->
        weaker_tier_consequence(:disabled_no_key)
    end
  end
end
