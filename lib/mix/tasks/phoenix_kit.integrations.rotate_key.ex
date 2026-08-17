defmodule Mix.Tasks.PhoenixKit.Integrations.RotateKey do
  @moduledoc """
  Rotates the encryption key protecting stored integration credentials.

  ## Usage

      $ mix phoenix_kit.integrations.rotate_key --dry-run
      $ mix phoenix_kit.integrations.rotate_key
      $ mix phoenix_kit.integrations.rotate_key --new-key="<already-generated-secret>"

  ## What it does

  1. Reads every stored integration connection.
  2. Decrypts each one under whichever key is CURRENTLY active (a
     dedicated `:integrations_encryption_key` if configured, else the
     legacy `secret_key_base`-derived key — see
     `PhoenixKit.Integrations.Encryption`).
  3. If every row decrypts cleanly, re-encrypts all of them under the new
     secret in a single database transaction — either every connection
     rotates, or (on any failure) none do.
  4. Prints the new secret (unless you supplied one with `--new-key`) and
     the config to set.

  This task does NOT write any config file or environment variable — you
  must configure `integrations_encryption_key` yourself (typically from an
  env var in `runtime.exs`) and restart the app.

  ## When to run this

    * **First adoption** — no dedicated key is configured yet, so every
      connection is protected only by the legacy `secret_key_base`-derived
      key. Run this once, set the printed secret, restart.
    * **Suspected key compromise** — a dedicated key is already configured.
      Run this, replace the env var with the newly printed secret, restart.
      Treat the old key as permanently compromised; do not reuse it.

  ## Options

    * `--dry-run` — runs the decrypt-and-verify pass over every row and
      reports how many WOULD rotate, without generating a key or writing
      anything. Unlike a real rotation, this does NOT take row locks —
      it's a plain read, safe to run against live traffic at any time, not
      just before committing to a real rotation.
    * `--new-key` — supply your own secret instead of generating one (e.g.
      one already stored in a secrets manager). Skipped in `--dry-run`. Must
      not be empty — `--new-key=""` is refused outright rather than
      silently falling back to a generated secret, since that's very likely
      a shell variable that resolved empty (`--new-key="$MAYBE_UNSET"`) and
      not something you meant to ask for.

  ## Run this with nothing else writing to integration connections

  A real rotation's row lock only defends against ONE direction of a race
  with a concurrent writer (an OAuth token auto-refresh, a "Test
  Connection" click, ...) — see `PhoenixKit.Integrations.KeyRotation`'s
  moduledoc, "Atomicity and concurrent writers", for the exact mechanism
  and what it does NOT cover. In short: a writer that already read a row
  before rotation locked it can still silently overwrite the freshly
  rotated row with old-key content after rotation commits, and `rotate/2`
  will have already reported success by then. **Pause anything that could
  write to integration connections (most concretely: an OAuth token-refresh
  worker) before running this for real, and do not resume it until you have
  restarted the app under the new key** — not just until this command
  returns. Treat the whole span, start to restart, as one maintenance
  window.

  ## The gap between rotating and restarting

  Rotation only changes what's in the database; the running app keeps using
  the OLD key until you set the new one and restart. This is the SAME
  maintenance window the section above requires — it doesn't end when this
  command returns, it ends when the app is running under the new key. In
  that window:

    * A READ of a rotated connection fails loudly (see
      `PhoenixKit.Integrations.Encryption`'s decrypt-failure handling) under
      the still-active old key.
    * A WRITE that must first read-and-merge the existing row (most writes
      in `PhoenixKit.Integrations` work this way) hits that same loud
      failure once it tries to decrypt a row this task already rotated.
    * A WRITE carrying values read BEFORE rotation ran — the race the
      section above describes — is not caught by that check at all: it
      lands silently, still encrypted under the OLD key, into a row this
      task already moved to the new secret. That value then fails to
      decrypt once the app restarts onto the new key, indistinguishable
      from unrelated corruption.

  There is no dual-key fallback to paper over any of this (it would
  silently mask exactly the failure class this task exists to prevent).
  Restart promptly, and keep writers paused until you do.
  """

  use Mix.Task

  alias PhoenixKit.Integrations.KeyRotation

  @shortdoc "Rotates the encryption key protecting stored integration credentials"

  @switches [dry_run: :boolean, new_key: :string]

  @impl Mix.Task
  def run(argv) do
    case parse_args(argv) do
      {:ok, opts} ->
        Mix.Task.run("app.start")
        if Keyword.get(opts, :dry_run, false), do: run_dry(), else: run_real(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # Parses this task's CLI args, `{:ok, opts} | {:error, message}`. Public
  # (but undocumented, `@doc false`) and pure — `run/1` isn't itself a
  # unit-test seam (it starts the app), but this decision is — same
  # reasoning as `Mix.Tasks.PhoenixKit.Repair.exit_code/1`. Deliberately
  # `strict:` rather than `switches:`: with `switches:`, an unrecognized or
  # misspelled flag — `--dryrun` instead of `--dry-run` — is silently
  # accepted as an extra boolean under its OWN (wrong) key rather than
  # erroring, so `Keyword.get(opts, :dry_run, false)` would quietly default
  # to `false` and run a REAL rotation instead of the dry run the caller
  # typed the flag to get. `strict:` turns that same typo into a parse
  # error here instead.
  @doc false
  @spec parse_args([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _argv, []} -> validate_new_key(opts)
      {_opts, _argv, errors} -> {:error, "Invalid option(s): #{format_option_errors(errors)}"}
    end
  end

  # An explicitly empty `--new-key=""` is refused rather than silently
  # treated as "flag not passed, generate one instead" — the fix for a
  # round-1 review finding that itself turned out to be risky. Generating
  # and using a random secret when the caller passed an EMPTY value (most
  # plausibly `--new-key="$SOME_VAR"` where the variable resolved empty) is
  # a real rotation under a key the caller never chose and that is printed
  # to stdout exactly once — if that output isn't captured, the credential
  # is unrecoverable even though the command "succeeded". Silently
  # substituting behavior for a value the caller DID supply, just wrong, is
  # the same class of surprise `strict:` above exists to prevent.
  defp validate_new_key(opts) do
    case Keyword.get(opts, :new_key) do
      "" ->
        {:error,
         "--new-key was passed but empty. Omit the flag entirely to generate a secret, or pass a real one."}

      _ ->
        {:ok, opts}
    end
  end

  defp format_option_errors(errors) do
    Enum.map_join(errors, ", ", fn
      {flag, nil} -> flag
      {flag, value} -> "#{flag}=#{inspect(value)}"
    end)
  end

  defp run_dry do
    # A dry run only needs the decrypt-and-verify pass — the "new secret"
    # never reaches an encrypt call, so a placeholder is fine here.
    case KeyRotation.rotate("dry-run-placeholder-unused", dry_run: true) do
      {:ok, %{rotated: n}} ->
        Mix.shell().info("OK — #{n} connection(s) would rotate cleanly. Nothing was written.")

      {:error, {:decrypt_failed, uuid, reason}} ->
        Mix.raise(decrypt_failed_message(uuid, reason))

      {:error, {:encryption_disabled, status}} ->
        Mix.raise(encryption_disabled_message(status))
    end
  end

  defp run_real(opts) do
    {new_secret, supplied?} = resolve_new_secret(opts)

    case KeyRotation.rotate(new_secret) do
      {:ok, %{rotated: n}} ->
        print_success(n, new_secret, supplied?)

      {:error, {:decrypt_failed, uuid, reason}} ->
        Mix.raise(decrypt_failed_message(uuid, reason))

      {:error, {:encryption_disabled, status}} ->
        Mix.raise(encryption_disabled_message(status))
    end
  end

  # Resolves the secret a real (non-dry-run) rotation writes under:
  # `{secret, supplied?}`. Trusts `opts` came through `parse_args/1`, which
  # already rejects an explicitly-empty `--new-key=""` (see
  # `validate_new_key/1`) — so `nil` here means the flag was genuinely never
  # passed, not "passed but empty", and generating a secret is unambiguously
  # correct. Public for the same testability reason as `parse_args/1`.
  @doc false
  @spec resolve_new_secret(keyword()) :: {String.t(), boolean()}
  def resolve_new_secret(opts) do
    case Keyword.get(opts, :new_key) do
      value when is_binary(value) -> {value, true}
      nil -> {generate_secret(), false}
    end
  end

  defp decrypt_failed_message(uuid, reason) do
    "Row #{uuid} failed to decrypt under the CURRENTLY active key (#{inspect(reason)}). " <>
      "Rotation aborted — NOTHING was written, not even for rows that decrypted fine. " <>
      "Investigate this row (it may already be encrypted under a different key from an " <>
      "earlier partial change, or genuinely corrupted) before retrying."
  end

  defp encryption_disabled_message(status) do
    "Refusing to rotate — encryption is not active (status: #{inspect(status)}). " <>
      "Rotation re-encrypts under a new secret; with no key active there is nothing " <>
      "meaningful to rotate. Set integration_encryption_enabled: true and configure a key " <>
      "first."
  end

  defp generate_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

  defp print_success(count, secret, supplied?) do
    Mix.shell().info("\nRotated #{count} connection(s).\n")

    unless supplied? do
      Mix.shell().info("""
      New secret (shown ONCE — copy it now, this task does not save it anywhere):

          #{secret}
      """)
    end

    Mix.shell().info("""
    Set it as the active key and restart the app, e.g. in runtime.exs:

        config :phoenix_kit, integrations_encryption_key: System.get_env("PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY")

    with the value above wired to that environment variable. Stored connections are now
    encrypted under the NEW secret — reads will fail until you configure it and restart,
    so don't delay between running this and restarting.
    """)
  end
end
