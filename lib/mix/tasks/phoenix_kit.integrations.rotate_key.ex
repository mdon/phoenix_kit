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

  Immediately after a (non-dry-run) rotation, stored connections are
  encrypted under the NEW secret, but the running app is still configured
  with the OLD key — reads will fail until you set the new key and restart.
  There is no dual-key fallback during that window (a silent fallback here
  would undermine the whole point: see
  `PhoenixKit.Integrations.Encryption`'s decrypt-failure handling). Restart
  promptly.
  """

  use Mix.Task

  alias PhoenixKit.Integrations.KeyRotation

  @shortdoc "Rotates the encryption key protecting stored integration credentials"

  @switches [dry_run: :boolean, new_key: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.start")

    if Keyword.get(opts, :dry_run, false) do
      run_dry()
    else
      run_real(opts)
    end
  end

  defp run_dry do
    # A dry run only needs the decrypt-and-verify pass — the "new secret"
    # never reaches an encrypt call, so a placeholder is fine here.
    case KeyRotation.rotate("dry-run-placeholder-unused", dry_run: true) do
      {:ok, %{rotated: n}} ->
        Mix.shell().info("OK — #{n} connection(s) would rotate cleanly. Nothing was written.")

      {:error, {:decrypt_failed, uuid, reason}} ->
        Mix.raise(decrypt_failed_message(uuid, reason))
    end
  end

  defp run_real(opts) do
    supplied_key = Keyword.get(opts, :new_key)
    new_secret = supplied_key || generate_secret()

    case KeyRotation.rotate(new_secret) do
      {:ok, %{rotated: n}} ->
        print_success(n, new_secret, supplied_key != nil)

      {:error, {:decrypt_failed, uuid, reason}} ->
        Mix.raise(decrypt_failed_message(uuid, reason))
    end
  end

  defp decrypt_failed_message(uuid, reason) do
    "Row #{uuid} failed to decrypt under the CURRENTLY active key (#{inspect(reason)}). " <>
      "Rotation aborted — NOTHING was written, not even for rows that decrypted fine. " <>
      "Investigate this row (it may already be encrypted under a different key from an " <>
      "earlier partial change, or genuinely corrupted) before retrying."
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
