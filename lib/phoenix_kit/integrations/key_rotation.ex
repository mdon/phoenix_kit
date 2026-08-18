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

  Refuses to run at all unless `Encryption.status/0` is `:dedicated` or
  `:legacy_secret_key_base` (an allowlist of the statuses that mean "a real
  key is active" — NOT a blocklist of the disabled ones, so a status this
  module doesn't recognize refuses by default instead of silently being
  treated as safe to rotate). With encryption off, "decrypt under the
  current key" is a no-op (nothing is actually encrypted), so a rotation
  would either silently leave already-plaintext values alone while
  encrypting only some fields, or report success while having changed
  nothing meaningful. Turn encryption on first.

  ## How it decides what "the current key" is

  `rotate/2` decrypts every row using whatever
  `PhoenixKit.Integrations.Encryption` currently resolves as active (the
  dedicated key if one is set, else the legacy fallback) — it does not take
  an "old secret" argument. This is deliberate: the running app is already
  using that key for every read, so it is unambiguous. Re-encryption happens
  under `new_secret`, passed explicitly, since that secret is NOT yet the
  active configured key at the moment rotation runs (setting it first would
  make the CURRENT rows unreadable before rotation even starts).

  ## Atomicity and concurrent writers — what the row lock does and does not buy

  A REAL (non-dry-run) rotation fetches every row with a row-level lock
  (`SELECT ... FOR UPDATE`) inside the SAME transaction that performs the
  write — not a plain read followed by a separate write transaction. `mix
  phoenix_kit.integrations.rotate_key --dry-run` does NOT take this lock
  (see below) — it is a pure read, safe to run against live traffic.

  This lock defends exactly ONE direction of the race against a concurrent
  writer (an OAuth token auto-refresh calling
  `PhoenixKit.Integrations.save_setup/4`, a "Test Connection" click, ...):
  if that writer is ALREADY mid-transaction against a row when rotation
  tries to lock it, rotation's `SELECT ... FOR UPDATE` blocks until the
  writer commits or rolls back — so rotation always re-encrypts the LATEST
  committed value, never a torn or stale one.

  **It does NOT defend the other direction.** If a writer already read a
  row (has old field values in memory) BEFORE rotation acquired the lock,
  that writer's own `UPDATE` — issued later, and possibly left queued
  behind rotation's lock in the meantime — still applies AFTER rotation
  commits, carrying content built from what it read and re-encrypted under
  whichever key was active when it computed that content: the OLD key,
  since the app's config never changes mid-rotation. That write silently
  overwrites rotation's freshly re-encrypted row with a value the NEW key
  cannot read. `rotate/2` already reported success by the time this
  happens — its transaction committed before the writer's queued `UPDATE`
  landed — and the affected field's later decrypt failure at restart is
  indistinguishable, from the log line alone, from unrelated corruption.

  Closing this properly needs either optimistic concurrency (a version
  column compared-and-swapped on every write — `PhoenixKit.Settings.Setting`
  does not carry one today, and adding one is a schema change touching
  every settings row in every install, not scoped to integrations) or
  making every OTHER write path in `PhoenixKit.Integrations` also
  read-lock inside a transaction (`save_setup/4`, `disconnect/3`,
  `record_validation/3`, `rename_connection/4`, `refresh_access_token/1` —
  a change to hot, already-shipped write paths well beyond what this
  rotation feature should carry). Neither is attempted here.

  **Practical consequence: nothing should write to `phoenix_kit_settings`
  rows where `module = "integrations"` from before you start a real
  rotation until the app has been restarted onto the new key** — not just
  for the few seconds `rotate/2` itself is running. A write landing
  anywhere in that whole span, including well after `rotate/2` has already
  returned `{:ok, _}`, can still land on the old key: silently reverting a
  row rotation just finished (this section), or getting silently stranded
  once the restart happens (see "The gap between rotating and restarting"
  below) — the same failure mode from either end of the same window. Pause
  anything that could write (most concretely: an OAuth token-refresh
  worker) before starting, and do not resume it until the restart is done
  — resuming as soon as `rotate/2` returns, before restarting, walks
  straight into this window. Treat the ENTIRE span — start to restart — as
  one maintenance window, not just the rotation command itself. The row
  lock narrows the race, it does not close it.

  A genuine write failure (a DB error while saving a re-encrypted row, not a
  decrypt failure) is NOT converted into an `{:error, _}` return — it raises,
  rolling back the transaction via the normal exception path. `rotate/2`'s
  own two-shape error type only covers the failure modes it can meaningfully
  name; an infrastructure failure should crash loudly, not get flattened
  into a tuple a caller might pattern-match past.

  If any row fails to decrypt under the current key, the whole transaction
  rolls back and NOTHING is written — a rotation that silently skipped a
  broken row would be exactly the kind of failure this module exists to
  prevent (see `PhoenixKit.Integrations.Encryption.decrypt_fields/1`'s own
  handling of a decrypt failure: it logs and drops the field rather than
  returning the raw ciphertext as if it were the value).

  ## The gap between rotating and restarting

  Rotation only changes what's IN THE DATABASE; the running app's
  configured key does not change until the operator edits config and
  restarts. In the window between those two events, on top of the
  concurrent-write race above:

    * **Reads** of a rotated connection do not raise or crash — a field
      that can't be decrypted under the still-active old key is logged
      (`Logger.error`) and silently dropped from whatever asked for it
      (see `PhoenixKit.Integrations.Encryption`'s decrypt-failure
      handling), same as any other decrypt failure. Not an exception a
      caller has to handle — the field is simply absent.
    * **A write that reads-and-merges the existing row and does NOT touch
      the stuck field is no longer destructive.** Most writes in
      `PhoenixKit.Integrations` work this way, including fully automatic
      ones (a validation-status update after every token-refresh attempt,
      with no operator involved) — and used to permanently erase a field
      it couldn't decrypt, because the map it saved back never had that
      field in it. That's fixed: such a write restores the field's
      untouched ciphertext from storage before saving, as long as the
      write itself doesn't supply a fresh value for that exact key. The
      field stays exactly as this rotation left it — encrypted under the
      NEW secret — and decrypts fine again the moment the app restarts.
    * **A write that DOES supply a fresh value for that exact field is
      still at risk.** Whatever gets encrypted at write time uses
      whichever key is ACTIVE, which is still the OLD one until the app
      restarts — so that one field lands back under the OLD key, in a row
      this rotation already moved to the NEW secret, and will fail to
      decrypt once the app restarts onto the new key, same as an
      un-rotated row would. This is the write half of the same race
      "Atomicity and concurrent writers" describes above, not a separate
      one.

  There is deliberately no dual-key read fallback to paper over this gap (it
  would silently mask exactly the class of failure this module exists to
  prevent). Restart promptly after rotating, and keep writers paused until
  you do — this gap is the SAME maintenance window "Atomicity and
  concurrent writers" above requires, not a separate, shorter one. It does
  not end when `rotate/2` returns; it ends when the app is running under
  the new key.
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
      against every row and writes nothing. Unlike a real rotation, this
      does NOT take row locks — it's a plain read, safe to run against live
      traffic — and does not require `new_secret` to be a real value the
      caller intends to use.

  Returns:

    * `{:ok, %{rotated: n, dry_run: boolean()}}` — success. In dry-run mode
      `rotated` is how many rows WOULD rotate.
    * `{:error, {:decrypt_failed, uuid, reason}}` — row `uuid` could not be
      decrypted under the currently active key. Nothing was written, not
      even for rows that decrypted fine — investigate the named row (it may
      already be encrypted under a different key from a prior partial
      change, or genuinely corrupted) before retrying.
    * `{:error, {:encryption_disabled, status}}` — refused to run;
      `Encryption.status/0` is not one of the recognized "a real key is
      active" statuses, so there is no active key for "rotate" to mean
      anything relative to.
  """
  @spec rotate(String.t(), keyword()) ::
          {:ok, %{rotated: non_neg_integer(), dry_run: boolean()}}
          | {:error, {:decrypt_failed, String.t(), failure_reason()}}
          | {:error, {:encryption_disabled, Encryption.key_status()}}
  def rotate(new_secret, opts \\ []) when is_binary(new_secret) and new_secret != "" do
    # Allowlist, not a blocklist of the disabled statuses: a status this
    # module doesn't recognize (a future addition to `key_status/0` that
    # doesn't fit either "safe to rotate" bucket) refuses by default
    # instead of silently being treated as active.
    case Encryption.status() do
      status when status in [:dedicated, :legacy_secret_key_base] ->
        do_rotate(new_secret, Keyword.get(opts, :dry_run, false))

      status ->
        {:error, {:encryption_disabled, status}}
    end
  end

  # The row-fetch query `rotate/2` runs inside its transaction — `lock: "FOR
  # UPDATE"` is what makes a concurrent writer BLOCK instead of racing (see
  # the moduledoc). Public and undocumented so a test can pass this exact
  # query through `Ecto.Adapters.SQL.to_sql/3` and confirm the lock clause
  # is genuinely in the SQL PhoenixKit sends, not just claimed in a comment
  # — `run/1`-style functions aren't a unit-test seam, but a pure query
  # builder is (same reasoning as `Mix.Tasks.PhoenixKit.Repair.exit_code/1`).
  # Used ONLY by a real rotation — `rotate_rows_query/0` (no lock) is what
  # dry-run reads through, so "just looking" never blocks a live writer.
  @doc false
  @spec locked_rows_query() :: Ecto.Query.t()
  def locked_rows_query do
    from(s in rotate_rows_query(), lock: "FOR UPDATE")
  end

  @doc false
  @spec rotate_rows_query() :: Ecto.Query.t()
  def rotate_rows_query do
    from(s in Setting, where: s.module == ^@settings_module)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Dry-run is a plain, unlocked read: it writes nothing and needs no
  # transactional consistency guarantee beyond "one consistent snapshot of
  # the table right now" (which a single SELECT already gives), so it must
  # not take FOR UPDATE locks or hold anything open against live traffic —
  # the whole point of a dry run is that running it has no side effects an
  # operator needs to reason about.
  defp do_rotate(_new_secret, true = _dry_run) do
    repo = PhoenixKit.RepoHelper.repo()
    rows = repo.all(rotate_rows_query())

    case decrypt_all(rows) do
      {:error, uuid, reason} ->
        {:error, {:decrypt_failed, uuid, reason}}

      {:ok, plans} ->
        {:ok, %{rotated: Enum.count(plans, &has_sensitive_field?/1), dry_run: true}}
    end
  end

  defp do_rotate(new_secret, false = _dry_run) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      rows = repo.all(locked_rows_query())

      case decrypt_all(rows) do
        {:error, uuid, reason} ->
          repo.rollback({:decrypt_failed, uuid, reason})

        {:ok, plans} ->
          to_rotate = Enum.filter(plans, &has_sensitive_field?/1)
          Enum.each(to_rotate, &rotate_row(&1, new_secret, repo))
          length(to_rotate)
      end
    end)
    |> normalize_result()
  end

  # A row scanned during the verify pass is not necessarily a row that
  # NEEDS rotating — one with no sensitive fields at all decrypts trivially
  # (nothing to decrypt) and re-encrypting it is a no-op that would still
  # issue an `UPDATE` with byte-identical `value_json`. Counting it as
  # "rotated" overstates what happened, and writing it wastes a row lock
  # for nothing. Scoped to rows that actually carry a sensitive field —
  # checked on the DECRYPTED view, not on whether the RAW stored value
  # already looks like `enc:v1:` ciphertext. That distinction matters: a
  # row written while encryption was off (or predating the feature) has a
  # genuine secret sitting in `value_json` as plain text, no prefix at
  # all. `Encryption.decrypt_fields/1` passes plaintext through unchanged,
  # so it still shows up in `decrypted` — checking the raw value instead
  # would silently skip exactly the rows a first rotation exists to
  # protect (reported success, wrote nothing, for a scenario that is
  # rotation's whole point per the moduledoc's "First adoption" case).
  defp has_sensitive_field?({_setting, decrypted}) do
    Enum.any?(Encryption.sensitive_fields(), fn field ->
      present?(Map.get(decrypted, field))
    end)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp rotate_row({setting, decrypted}, new_secret, repo) do
    new_value = Encryption.encrypt_fields_with_secret(decrypted, new_secret)

    setting
    |> Setting.update_changeset(%{value_json: new_value})
    |> repo.update!()
  end

  defp normalize_result({:ok, count}), do: {:ok, %{rotated: count, dry_run: false}}
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
