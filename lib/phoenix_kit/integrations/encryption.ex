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
          store:
            :absent
            | {:no_secret_yet, String.t()}
            | {:unreadable, String.t()}
            | {:holding, String.t()},
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
          key_store: nil | {:no_secret_yet | :unreadable | :holding, String.t()}
        }

  # ONE read of each input, and every signal derived from those three values.
  # This used to be four independent resolutions — the tier, the too-short
  # check, the store state and the fingerprint each went back to the
  # environment — and `KeyStore.cached_read/0` deliberately does not memoise
  # FAILURES, so a store that failed one read and answered the next produced a
  # map that contradicted itself. Reproduced before this changed, with a store
  # that fails only its first read:
  #
  #     tier: :legacy, store: {:holding, _}, fingerprint: {:ok, "2395aad025c3"}
  #     rendered as: "DERIVED from secret_key_base", "derived from secret_key_base"
  #     fp(secret_key_base) = 826f21f672e5   <- what the label claimed
  #     fp(stored secret)   = 2395aad025c3   <- what was printed
  #
  # The verdict being a pure function of this map buys nothing while the map is
  # itself stitched together from four different answers to the same question.
  @doc """
  Reads every signal the key verdict depends on, in one pass.
  """
  @spec key_signals() :: key_signals()
  def key_signals do
    enabled? = encryption_enabled_flag?()
    {{tier, secret, too_short?}, store_read} = resolve_once()

    %{
      enabled?: enabled?,
      tier: tier,
      too_short?: too_short?,
      store: store_state(store_read),
      fingerprint: fingerprint_for(enabled?, secret)
    }
  end

  # Three absences the advice must keep apart, not two: no store at all, a store
  # that is configured and does not hold a secret yet, and a store that holds
  # one nobody can read. `KeyStore.read/0`'s own doc forbids collapsing the last
  # two — "no key yet" invites writing one, "could not read" must never lead to
  # overwriting one — and this function was collapsing the FIRST two instead: a
  # configured store whose file does not exist yet reads `:not_configured`, and
  # that was reported as `{:holding, _}`. Verified by running: a store pointed at
  # a path that does not exist produced `{:holding, "…/not-created-yet.key"}`,
  # so `{:no_secret_yet, _}` was a signal value production could never emit
  # while the tests enumerated it as one of four.
  defp store_state(store_read) do
    if KeyStore.configured?() do
      location = KeyStore.describe() || "the configured key store"

      case store_read do
        {:error, _reason} -> {:unreadable, location}
        :not_configured -> {:no_secret_yet, location}
        _held -> {:holding, location}
      end
    else
      :absent
    end
  end

  defp fingerprint_for(false, _secret), do: :none
  defp fingerprint_for(true, nil), do: :none
  defp fingerprint_for(true, secret), do: {:ok, fingerprint(derive_key(secret))}

  @doc """
  The complete report for the current state.
  """
  @spec key_report() :: key_report()
  def key_report, do: key_report(key_signals())

  @doc """
  The verdict for a set of signals — total over the signal space.

  Public because the acceptance criterion here is an enumeration: every
  combination rendered whole and read for self-contradiction. That needs a seam
  that takes the state rather than discovering it.

  ## Ordered by the tier first, and deliberately

  Three rounds ordered the clauses by fault — unreadable store, then short key,
  then tier — and each round found a state where the fault clause fired over a
  tier that was working, and announced a fallback that was not happening. The
  fix each time was to move one clause; the next round found the next one.

  The tier is the ground truth: it is *which key is protecting the data right
  now*. A fault is a modifier on that, never a replacement for it. So the tier
  is matched first and the fault second, which has two consequences worth
  stating:

    * no combination of signals can produce a report claiming a fallback while
      the signals say a dedicated key is in use — not because that combination
      is argued to be unreachable, but because no clause can say it;
    * the verdict is **total**. Every point in the signal space renders, and the
      test walks all of them rather than filtering by a reachability rule.
      Reachability rules were themselves the defect twice: they were reasoned
      out by whoever reasoned out the code, and they excluded states the code
      could actually reach.

  Within a tier, the faults are ordered by which one an operator must clear
  first. For the weaker tiers a rejected key outranks an unreadable store,
  because `dedicated_candidate/2` never consults the store while config answers
  — so repairing the store cannot change anything until the short key is gone.
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

  # --- the dedicated tier: a key of this site's own is doing the work --------

  # Encryption is working; what is broken is the spare copy. The consequence
  # used to promise that "the next rotation will refuse at its pre-flight",
  # which was false twice over, and both halves were checked by running:
  #
  #   * `KeyStore.preflight/0` writes a probe file NEXT TO the secret and
  #     removes it. An unreadable secret in a writable directory answers `:ok`;
  #   * `KeyRotation.rotate/2` does not run a pre-flight at all. With
  #     `preflight/0` returning `{:error, {:inside_repository, _}}`, `rotate/2`
  #     walked straight past it into the row scan. Only the mix task checks.
  def key_report(%{tier: :dedicated, store: {:unreadable, location}} = signals) do
    report(signals, {:dedicated, :store_unreadable}, :warn,
      summary:
        "a dedicated encryption key is in use, but the configured key store could not be read",
      consequence:
        "encryption itself is fine — the key in use comes from configuration. What is broken " <>
          "is the spare copy: nothing confirms this key is saved anywhere, and a rotation " <>
          "will not be stopped by it, because the pre-flight checks that the store can be " <>
          "WRITTEN, not that it can be read",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` until the store reads back — " <>
          "repair it at #{location} first, and until it does, assume the key is saved nowhere",
      rotation_safe?: false,
      tier_label: "dedicated key"
    )
  end

  def key_report(%{tier: :dedicated} = signals) do
    report(signals, {:dedicated, :ok}, :ok,
      summary: "a dedicated encryption key is in use",
      consequence: "",
      action: "",
      rotation_safe?: true,
      tier_label: "dedicated key"
    )
  end

  # --- the legacy tier: secret_key_base is doing the work --------------------

  # Ordered above the unreadable store, unlike every earlier round. While a
  # rejected key is set in config the store is never consulted (verified by
  # running), so "repair the store" is advice that cannot help until this is
  # cleared — and it is the only clause that says so.
  def key_report(%{tier: :legacy, too_short?: true} = signals) do
    report(signals, {:legacy_secret_key_base, :key_too_short}, :warn,
      summary: too_short_summary(),
      consequence: fallback_consequence(),
      action: replace_key_action(),
      rotation_safe?: true,
      tier_label: "FALLBACK key — the configured key was rejected as too short"
    )
  end

  def key_report(%{tier: :legacy, store: {:unreadable, location}} = signals) do
    report(signals, {:legacy_secret_key_base, :store_unreadable}, :warn,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence: fallback_consequence(),
      action: repair_store_action(:fallback),
      rotation_safe?: false,
      tier_label: "FALLBACK key — the configured key store could not be read"
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

  # --- no tier at all: everything is going to the database in the clear ------

  # `rotation_safe?` is false for every clause here and the advice says why:
  # `KeyRotation.rotate/2` refuses outright while no key is active, verified by
  # running — `{:error, {:encryption_disabled, :disabled_no_key}}`. This clause
  # used to advise the rotation anyway and mark it safe, which is the same
  # wrong recommendation an earlier round removed from the clause next to it.
  def key_report(%{tier: :none, too_short?: true} = signals) do
    report(signals, {:disabled_no_key, :key_too_short}, :fail,
      summary: too_short_summary(),
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` — it refuses while no key is " <>
          "active. Replace integrations_encryption_key with a secret of at least " <>
          "#{@min_dedicated_key_length} characters and restart",
      rotation_safe?: false,
      tier_label: nil
    )
  end

  def key_report(%{tier: :none, store: {:unreadable, location}} = signals) do
    report(signals, {:disabled_no_key, :store_unreadable}, :fail,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action: repair_store_action(:no_key),
      rotation_safe?: false,
      tier_label: nil
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

  # The location alone reads as "your key is saved here", which is exactly what
  # it does NOT mean for two of the three states — and one of those states could
  # not even be produced until `store_state/1` stopped collapsing it.
  defp store_location(:absent), do: nil
  defp store_location({state, location}), do: {state, location}

  defp fallback_consequence,
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"

  defp repair_store_action(:fallback),
    do:
      "Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key " <>
        "may still be the one your data is encrypted under. Repair the store first; " <>
        "repairing it later will NOT make anything written in the meantime readable"

  # The sentence above is false here, and false in the direction that matters.
  # With no key resolving, what is being written is not ciphertext under a
  # weaker key — it is PLAINTEXT (verified by running `encrypt_fields/1` in this
  # state: the value is stored verbatim). Repairing the store later leaves those
  # rows exactly as readable as they are now, to anyone with database access.
  # They do not need decrypting; they need rewriting.
  defp repair_store_action(:no_key),
    do:
      "Do NOT run `mix phoenix_kit.integrations.rotate_key` — it refuses while no key is " <>
        "active, and the stored key may be the one existing credentials are encrypted under. " <>
        "Repair the store first: every credential written meanwhile goes to the database in " <>
        "the clear and STAYS readable after the repair, so re-save those connections once a " <>
        "key is active"

  defp too_short_summary,
    do:
      "a dedicated key IS configured but was rejected as shorter than " <>
        "#{@min_dedicated_key_length} characters, which is not the same as none being " <>
        "configured"

  defp replace_key_action,
    do:
      "Replace integrations_encryption_key with a real secret — while a rejected key sits " <>
        "there the key store is not consulted at all, so repairing or filling the store " <>
        "changes nothing. `mix phoenix_kit.integrations.rotate_key` generates one, and " <>
        "stores it for you if a key store is configured"

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
      key when is_binary(key) -> {:ok, fingerprint(key)}
      _ -> :none
    end
  end

  defp fingerprint(key) do
    :sha256
    |> :crypto.pbkdf2_hmac(key, @fingerprint_domain, @fingerprint_iterations, 6)
    |> Base.encode16(case: :lower)
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
    case resolve_once() do
      {{:none, _secret, _short?}, _store_read} -> :none
      {{tier, secret, _short?}, _store_read} -> {tier, secret}
    end
  end

  # One store read, one resolution, and the store-failure log emitted from
  # inside it — so the log knows which tier actually resolved instead of
  # guessing from the environment.
  defp resolve_once do
    store_read = read_store()
    resolution = resolve(configured_key(), store_read, secret_key_base())
    maybe_log_store_failure(store_read, resolution)
    {resolution, store_read}
  end

  # The whole tier resolution as a pure function of the three raw reads, so the
  # hot path and the diagnostics cannot reach different conclusions about the
  # same inputs — they no longer read the inputs separately.
  @spec resolve(term(), term(), String.t() | nil) ::
          {:dedicated | :legacy | :none, String.t() | nil, boolean()}
  defp resolve(config_key, store_read, secret_key_base) do
    case dedicated_candidate(config_key, store_read) do
      {:ok, secret} ->
        {:dedicated, secret, false}

      rejected ->
        too_short? = rejected == :too_short

        case secret_key_base do
          secret when is_binary(secret) and secret != "" -> {:legacy, secret, too_short?}
          _ -> {:none, nil, too_short?}
        end
    end
  end

  # Explicit configuration wins, and the store is not consulted at all when
  # config answers — INCLUDING when what it answers with is rejected as too
  # short. That is not a detail of ordering: verified by running, a store
  # holding a perfectly good secret resolves to `:dedicated` on its own and
  # drops to `:legacy_secret_key_base` the moment a short
  # `:integrations_encryption_key` is added. So while a rejected key sits in
  # config, repairing or filling the key store changes nothing, and any advice
  # that says otherwise is sending an operator to the wrong file.
  #
  # A secret persisted by `PhoenixKit.Integrations.KeyStore` is the same
  # `:dedicated` tier — a dedicated key the operator did not have to paste into
  # config by hand after rotating.
  defp dedicated_candidate({:ok, secret}, _store_read) when is_binary(secret) and secret != "",
    do: check_dedicated_length(secret)

  defp dedicated_candidate(_config, {:ok, secret}) when is_binary(secret) and secret != "",
    do: check_dedicated_length(secret)

  defp dedicated_candidate(_config, _store_read), do: :unset

  defp configured_key, do: PhoenixKit.Config.get(:integrations_encryption_key)

  # Reads the store through the memoised path — encryption runs once per
  # encrypted field, and an unmemoised read would open a file every time.
  #
  # A configured store that cannot be READ is not the same as no store, and
  # collapsing the two is how a fleet quietly splits in half: the app falls
  # through to the weaker `:legacy` tier, old values stop decrypting, and NEW
  # values get written under the legacy key. Fixing the file later then leaves
  # those new rows unreadable forever. The fallback is kept — refusing outright
  # would resolve to no key at all, and a nil key makes writes store plaintext,
  # which is worse — but it is never silent.
  defp read_store, do: KeyStore.cached_read()

  defp maybe_log_store_failure({:error, reason}, {tier, _secret, _short?}),
    do: log_store_failure_once(reason, tier)

  defp maybe_log_store_failure(_store_read, _resolution), do: :ok

  # Encryption runs once per credential field and read failures are deliberately
  # not cached, so this would otherwise repeat per field, per request. One line
  # per VM is enough to be found.
  defp log_store_failure_once(reason, tier) do
    key = {__MODULE__, :store_failure_logged}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.error(
        "[PhoenixKit.Integrations] A key store IS configured but its secret could not be " <>
          "read (#{KeyStore.describe_error(reason)}): #{weaker_tier_consequence(tier)}. " <>
          "#{store_failure_urgency(tier)}"
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
  # A third case, and the one this used to get wrong. The caller was described
  # as "the one caller that genuinely cannot be handed a status: it runs DURING
  # tier resolution, so asking for one would recurse", and it inferred the
  # consequence from `secret_key_base/0` alone. That inference has no way to
  # notice a dedicated key resolving from CONFIG, so an install with a working
  # dedicated key and a broken store was told at boot that "encryption fell back
  # to the secret_key_base-derived key" — the same false fallback claim this
  # module has now had removed from four other surfaces, sitting in the one
  # place that was exempted from the fix.
  #
  # The exemption was real but is no longer: since the resolution became a pure
  # function of three reads, the tier is known at the call site without a second
  # look at anything.
  # The tail of the boot line, for the same reason as the head: "repairing the
  # store later will not make anything written in the meantime readable" is
  # true only where writes are landing under a key the repair abandons. On the
  # dedicated tier nothing of the sort is happening.
  defp store_failure_urgency(:dedicated),
    do: "Fix the store so this key has a copy somewhere; nothing needs rewriting."

  defp store_failure_urgency(_tier),
    do:
      "Repairing the store later will not make anything written in the meantime readable. " <>
        "Fix the store before writing anything else."

  defp weaker_tier_consequence(:dedicated),
    do:
      "the key in use comes from configuration, so encryption itself is unaffected — but " <>
        "nothing is backing that key up"

  defp weaker_tier_consequence(:none),
    do: "NO key resolved at all — integration credentials are being written in PLAINTEXT"

  defp weaker_tier_consequence(:legacy),
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"
end
