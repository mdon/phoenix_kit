defmodule PhoenixKit.Integrations.KeyRotation do
  @moduledoc """
  Re-encrypts every stored integration connection under a new encryption
  secret.

  Needed any time the secret backing `PhoenixKit.Integrations.Encryption`
  changes:

    * **First adoption of a dedicated key** — every connection is currently
      encrypted under the legacy `secret_key_base`-derived key
      (`status/0` reports `:legacy_secret_key_base`); this migrates them to
      a dedicated `:integrations_encryption_key`.
    * **Rotating an existing dedicated key** — e.g. after a suspected
      compromise.

  Without this, changing the active key makes every previously-encrypted
  `enc:v1:` value undecryptable — see `PhoenixKit.Integrations.Encryption`'s
  moduledoc on key rotation. `mix phoenix_kit.integrations.rotate_key` wraps
  this module for interactive use.

  ## How it decides what "the current key" is

  `rotate/2` decrypts every row using whatever
  `PhoenixKit.Integrations.Encryption` currently resolves as active (the
  dedicated key if one is set, else the legacy fallback) — it does not take
  an "old secret" argument. This is deliberate: the running app is already
  using that key for every read, so it is unambiguous. Re-encryption happens
  under `new_secret`, passed explicitly, since that secret is NOT yet the
  active configured key at the moment rotation runs (setting it first would
  make the CURRENT rows unreadable before rotation even starts).

  ## Atomicity

  All rows are decrypted and verified BEFORE any write. If any row fails to
  decrypt under the current key, `rotate/2` returns an error and writes
  NOTHING — a rotation that silently skipped a broken row would be exactly
  the kind of failure this module exists to prevent (see the "does this
  code ever fire" note in `PhoenixKit.Integrations.Encryption`'s decrypt
  path). When every row decrypts cleanly, the re-encrypted values are
  written inside a single database transaction — either every connection
  rotates, or none do.

  ## After a successful rotation

  The rows are now encrypted under `new_secret`, but the app's configured
  key has not changed — reads will fail (loudly, per the decrypt-failure
  fix above) until the operator sets `new_secret` as
  `:integrations_encryption_key` and restarts. Do this promptly; there is
  no dual-key read fallback during the gap.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Settings.Setting

  @settings_module "integrations"

  @typedoc "Why a row was left untouched — always paired with its uuid."
  @type failure_reason :: :decrypt_failed_under_current_key

  @doc """
  Re-encrypts every stored integration connection under `new_secret`.

  `opts`:

    * `:dry_run` (default `false`) — runs the decrypt-and-verify pass
      against every row (proving they're all readable under the current
      key) but writes nothing and does not require `new_secret` to be a
      real value the caller intends to use.

  Returns:

    * `{:ok, %{rotated: n, dry_run: boolean()}}` — success. In dry-run mode
      `rotated` is how many rows WOULD rotate.
    * `{:error, {:decrypt_failed, uuid, reason}}` — row `uuid` could not be
      decrypted under the currently active key. Nothing was written, not
      even for rows that decrypted fine — investigate the named row (it may
      already be encrypted under a different key from a prior partial
      change, or genuinely corrupted) before retrying.
  """
  @spec rotate(String.t(), keyword()) ::
          {:ok, %{rotated: non_neg_integer(), dry_run: boolean()}}
          | {:error, {:decrypt_failed, String.t(), failure_reason()}}
  def rotate(new_secret, opts \\ []) when is_binary(new_secret) and new_secret != "" do
    dry_run = Keyword.get(opts, :dry_run, false)
    repo = PhoenixKit.RepoHelper.repo()

    rows = from(s in Setting, where: s.module == ^@settings_module) |> repo.all()

    case decrypt_all(rows) do
      {:error, uuid, reason} ->
        {:error, {:decrypt_failed, uuid, reason}}

      {:ok, plans} ->
        if dry_run do
          {:ok, %{rotated: length(plans), dry_run: true}}
        else
          write_all(plans, new_secret, repo)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Decrypts every row under the CURRENTLY active key and confirms nothing
  # was silently dropped by `Encryption.decrypt_fields/1`'s failure path —
  # any originally-`enc:v1:`-prefixed field that didn't come back means that
  # field failed to decrypt. Halts on the first such row: partial results
  # here would tempt a caller into writing SOME rows under the new secret
  # while leaving others on the old one, which is the exact mixed state
  # atomicity is meant to prevent.
  defp decrypt_all(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn setting, {:ok, acc} ->
      original = setting.value_json || %{}
      decrypted = Encryption.decrypt_fields(original)

      if decrypt_failed?(original, decrypted) do
        {:halt, {:error, setting.uuid, :decrypt_failed_under_current_key}}
      else
        {:cont, {:ok, [{setting, decrypted} | acc]}}
      end
    end)
  end

  defp decrypt_failed?(original, decrypted) do
    Enum.any?(Encryption.sensitive_fields(), fn field ->
      case Map.get(original, field) do
        "enc:v1:" <> _ -> not Map.has_key?(decrypted, field)
        _ -> false
      end
    end)
  end

  defp write_all(plans, new_secret, repo) do
    plans
    |> Enum.reverse()
    |> then(fn ordered ->
      repo.transaction(fn ->
        Enum.each(ordered, fn {setting, decrypted} ->
          new_value = Encryption.encrypt_fields_with_secret(decrypted, new_secret)

          setting
          |> Setting.update_changeset(%{value_json: new_value})
          |> repo.update!()
        end)

        length(ordered)
      end)
    end)
    |> case do
      {:ok, count} -> {:ok, %{rotated: count, dry_run: false}}
      {:error, reason} -> {:error, reason}
    end
  end
end
