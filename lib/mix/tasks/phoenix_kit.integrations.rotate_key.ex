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
      anything. Use this first to catch an already-broken row before
      committing to a real rotation.
    * `--new-key` — supply your own secret instead of generating one (e.g.
      one already stored in a secrets manager). Skipped in `--dry-run`.

  ## The gap between rotating and restarting

  Rotation only changes what's in the database; the running app keeps using
  the OLD key until you set the new one and restart. In that window, READS
  of a rotated connection fail loudly (see
  `PhoenixKit.Integrations.Encryption`'s decrypt-failure handling) — and so
  does any WRITE that lands in the meantime (most notably an OAuth token
  auto-refresh), since it saves under the still-active OLD key into a row
  this task already moved to the new secret. There is no dual-key fallback
  to paper over this (it would silently mask exactly the failure class this
  task exists to prevent). Restart promptly — treat the window as a brief
  maintenance window, not a fire-and-forget background step.
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
      {opts, _argv, []} -> {:ok, opts}
      {_opts, _argv, errors} -> {:error, "Invalid option(s): #{format_option_errors(errors)}"}
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
  # `{secret, supplied?}`. An empty `--new-key=""` behaves like the flag was
  # never passed at all (generates a fresh secret) rather than like a real,
  # empty secret was supplied — the latter would reach
  # `KeyRotation.rotate/2`'s `new_secret != ""` guard and crash with an
  # unhelpful `FunctionClauseError` instead of doing the obviously-intended
  # thing. Public for the same testability reason as `parse_args/1`.
  @doc false
  @spec resolve_new_secret(keyword()) :: {String.t(), boolean()}
  def resolve_new_secret(opts) do
    case Keyword.get(opts, :new_key) do
      value when is_binary(value) and value != "" -> {value, true}
      _ -> {generate_secret(), false}
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
