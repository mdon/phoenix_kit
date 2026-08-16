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

  Refuses to run at all when `Encryption.status/0` is `:disabled_no_key` or
  `:disabled_explicit` — with encryption off, "decrypt under the current
  key" is a no-op (nothing is actually encrypted), so a rotation would
  either silently leave already-plaintext values alone while encrypting
  only some fields, or report success while having changed nothing
  meaningful. Turn encryption on first.

  ## How it decides what "the current key" is

  `rotate/2` decrypts every row using whatever
  `PhoenixKit.Integrations.Encryption` currently resolves as active (the
  dedicated key if one is set, else the legacy fallback) — it does not take
  an "old secret" argument. This is deliberate: the running app is already
  using that key for every read, so it is unambiguous. Re-encryption happens
  under `new_secret`, passed explicitly, since that secret is NOT yet the
  active configured key at the moment rotation runs (setting it first would
  make the CURRENT rows unreadable before rotation even starts).

  ## Atomicity and concurrent writers

  Every row is read with a row-level lock (`SELECT ... FOR UPDATE`) inside
  the SAME transaction that performs the write — not a plain read followed
  by a separate write transaction. That matters: this table also takes
  writes from live traffic (an OAuth token auto-refresh calling
  `PhoenixKit.Integrations.save_setup/4`, a "Test Connection" click stamping
  `last_validated_at`, ...). Reading rows outside a lock and writing a
  re-encrypted snapshot back later would silently overwrite any such
  concurrent write with a stale copy — the row-level lock instead makes a
  concurrent writer BLOCK until this transaction commits or rolls back, so
  no write is ever lost to a lost-update race.

  A genuine write failure (a DB error while saving a re-encrypted row, not a
  decrypt failure) is NOT converted into an `{:error, _}` return — it raises,
  rolling back the transaction via the normal exception path. `rotate/2`'s
  own two-shape error type only covers the failure modes it can meaningfully
  name; an infrastructure failure should crash loudly, not get flattened
  into a tuple a caller might pattern-match past.

  If any row fails to decrypt under the current key, the whole transaction
  rolls back and NOTHING is written — a rotation that silently skipped a
  broken row would be exactly the kind of failure this module exists to
  prevent (see the "does this code ever fire" note in
  `PhoenixKit.Integrations.Encryption`'s decrypt path).

  ## The gap between rotating and restarting

  Rotation only changes what's IN THE DATABASE; the running app's
  configured key does not change until the operator edits config and
  restarts. In the window between those two events:

    * **Reads** of a rotated connection fail (loudly — see
      `PhoenixKit.Integrations.Encryption`'s decrypt-failure handling) under
      the still-active old key.
    * **Writes** are just as affected, not only reads: anything that saves
      new credential data during the window — most notably an OAuth token
      auto-refresh — is encrypted under the OLD key (still the active
      config), landing back in a row this rotation already moved to the
      NEW secret. That write's own credential value will then fail to
      decrypt once the app is restarted onto the new key, exactly like an
      un-rotated row would.

  There is deliberately no dual-key read fallback to paper over this gap (it
  would silently mask exactly the class of failure this module exists to
  prevent). Restart promptly after rotating; for a connection with an
  active OAuth refresh cycle, treat the rotation window like a brief
  maintenance window rather than a fire-and-forget background task.
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
      against every row, under the same row locks a real run would take
      (released immediately, nothing is written) but writes nothing and
      does not require `new_secret` to be a real value the caller intends
      to use.

  Returns:

    * `{:ok, %{rotated: n, dry_run: boolean()}}` — success. In dry-run mode
      `rotated` is how many rows WOULD rotate.
    * `{:error, {:decrypt_failed, uuid, reason}}` — row `uuid` could not be
      decrypted under the currently active key. Nothing was written, not
      even for rows that decrypted fine — investigate the named row (it may
      already be encrypted under a different key from a prior partial
      change, or genuinely corrupted) before retrying.
    * `{:error, {:encryption_disabled, status}}` — refused to run;
      `Encryption.status/0` is `:disabled_no_key` or `:disabled_explicit`,
      so there is no active key for "rotate" to mean anything relative to.
  """
  @spec rotate(String.t(), keyword()) ::
          {:ok, %{rotated: non_neg_integer(), dry_run: boolean()}}
          | {:error, {:decrypt_failed, String.t(), failure_reason()}}
          | {:error, {:encryption_disabled, Encryption.key_status()}}
  def rotate(new_secret, opts \\ []) when is_binary(new_secret) and new_secret != "" do
    case Encryption.status() do
      status when status in [:disabled_no_key, :disabled_explicit] ->
        {:error, {:encryption_disabled, status}}

      _active ->
        do_rotate(new_secret, Keyword.get(opts, :dry_run, false))
    end
  end

  # The row-fetch query `rotate/2` runs inside its transaction — `lock: "FOR
  # UPDATE"` is what makes a concurrent writer BLOCK instead of racing (see
  # the moduledoc). Public and undocumented so a test can pass this exact
  # query through `Ecto.Adapters.SQL.to_sql/3` and confirm the lock clause
  # is genuinely in the SQL PhoenixKit sends, not just claimed in a comment
  # — `run/1`-style functions aren't a unit-test seam, but a pure query
  # builder is (same reasoning as `Mix.Tasks.PhoenixKit.Repair.exit_code/1`).
  @doc false
  @spec locked_rows_query() :: Ecto.Query.t()
  def locked_rows_query do
    from(s in Setting, where: s.module == ^@settings_module, lock: "FOR UPDATE")
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_rotate(new_secret, dry_run) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      rows = repo.all(locked_rows_query())

      case decrypt_all(rows) do
        {:error, uuid, reason} ->
          repo.rollback({:decrypt_failed, uuid, reason})

        {:ok, plans} ->
          if dry_run do
            # Rows were locked to get a consistent count, but a dry run
            # writes nothing — rollback releases the locks immediately
            # instead of holding them for the length of a real rotation.
            repo.rollback({:dry_run, length(plans)})
          else
            Enum.each(plans, &rotate_row(&1, new_secret, repo))
            length(plans)
          end
      end
    end)
    |> normalize_result()
  end

  defp rotate_row({setting, decrypted}, new_secret, repo) do
    new_value = Encryption.encrypt_fields_with_secret(decrypted, new_secret)

    setting
    |> Setting.update_changeset(%{value_json: new_value})
    |> repo.update!()
  end

  defp normalize_result({:ok, count}), do: {:ok, %{rotated: count, dry_run: false}}
  defp normalize_result({:error, {:dry_run, count}}), do: {:ok, %{rotated: count, dry_run: true}}
  defp normalize_result({:error, {:decrypt_failed, _uuid, _reason}} = error), do: error

  # Decrypts every row under the CURRENTLY active key and confirms nothing
  # was silently dropped by `Encryption.decrypt_fields/1`'s failure path —
  # any originally-encrypted field that didn't come back means that field
  # failed to decrypt. Halts on the first such row: partial results here
  # would tempt a caller into writing SOME rows under the new secret while
  # leaving others on the old one, which is the exact mixed state atomicity
  # is meant to prevent.
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
      value = Map.get(original, field)
      Encryption.encrypted?(value) and not Map.has_key?(decrypted, field)
    end)
  end
end
