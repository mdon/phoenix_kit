defmodule Mix.Tasks.PhoenixKit.Integrations.RotateKeyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Integrations.RotateKey, as: RotateKeyTask
  alias PhoenixKit.Integrations.Encryption

  # `run/1` itself isn't a good unit-test seam (starts the app, needs a real
  # DB) — see `Mix.Tasks.PhoenixKit.Repair.exit_code/1` for the established
  # pattern this follows: exercise the pure decisions the task makes.

  describe "parse_args/1 — the typo-safety fix" do
    test "--dry-run parses to dry_run: true" do
      assert {:ok, opts} = RotateKeyTask.parse_args(["--dry-run"])
      assert Keyword.get(opts, :dry_run) == true
    end

    test "no args parses to an empty opts list (dry_run defaults false downstream)" do
      assert {:ok, []} = RotateKeyTask.parse_args([])
    end

    # Was `--new-key=abc123`. That six-character value now fails the length
    # check added alongside the key store: Encryption rejects anything shorter
    # than its minimum as too weak, so accepting it here meant re-encrypting
    # every row under a key the app would refuse on the next boot. The parse
    # itself is what this test is about, so it uses a key of a realistic length.
    test "--new-key=<value> parses through" do
      value = String.duplicate("k", 32)
      assert {:ok, opts} = RotateKeyTask.parse_args(["--new-key=" <> value])
      assert Keyword.get(opts, :new_key) == value
    end

    test "a misspelled flag is REJECTED, not silently ignored" do
      # With non-strict OptionParser parsing, "--dryrun" (missing hyphen)
      # would be accepted as an unrelated boolean flag under its own wrong
      # key, `dry_run` would silently stay `false`, and the task would run
      # a REAL rotation instead of the dry run the caller typed this flag
      # to get. `strict:` turns that into a parse error instead.
      assert {:error, message} = RotateKeyTask.parse_args(["--dryrun"])
      assert message =~ "dryrun"
    end

    test "an unknown flag entirely is REJECTED" do
      assert {:error, message} = RotateKeyTask.parse_args(["--wat"])
      assert message =~ "wat"
    end

    test "a wrong-type value for a known flag is REJECTED" do
      assert {:error, _message} = RotateKeyTask.parse_args(["--dry-run=notaboolean"])
    end

    test "an explicitly empty --new-key=\"\" is REJECTED, not silently substituted" do
      # Treating "" like the flag was never passed (generate a fresh
      # secret instead) would be its own hazard: `--new-key="$MAYBE_UNSET"`
      # with an empty variable would silently rotate under a RANDOM key
      # the caller never chose, printed to stdout exactly once —
      # unrecoverable if that output isn't captured. An explicitly-empty
      # value the caller DID pass must be rejected, the same way a
      # misspelled flag is, not quietly replaced with different behavior.
      assert {:error, message} = RotateKeyTask.parse_args(["--new-key="])
      assert message =~ "new-key"
      assert message =~ "empty"
    end
  end

  describe "resolve_new_secret/1" do
    test "a supplied non-empty key is used as-is, marked supplied" do
      assert {"abc123", true} = RotateKeyTask.resolve_new_secret(new_key: "abc123")
    end

    test "no --new-key generates a fresh, non-empty secret, marked not supplied" do
      assert {secret, false} = RotateKeyTask.resolve_new_secret([])
      assert is_binary(secret) and secret != ""
    end
  end

  describe "--new-key is refused when the app would later reject it" do
    # Without this the rotation "succeeds", the rows are rewritten under a key
    # Encryption rejects as too weak on the next boot, and everything rotated
    # becomes unreadable — while the task reported the secret safely stored.
    test "a key shorter than the accepted minimum is refused before anything runs" do
      short =
        String.duplicate("a", Encryption.min_dedicated_key_length() - 1)

      assert {:error, message} = RotateKeyTask.parse_args(["--new-key=" <> short])
      assert message =~ "minimum accepted"
      assert message =~ "Nothing was changed"
    end

    test "a key at exactly the minimum is accepted" do
      ok = String.duplicate("a", Encryption.min_dedicated_key_length())

      assert {:ok, opts} = RotateKeyTask.parse_args(["--new-key=" <> ok])
      assert Keyword.get(opts, :new_key) == ok
    end
  end
end
