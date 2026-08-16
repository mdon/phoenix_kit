defmodule Mix.Tasks.PhoenixKit.Integrations.RotateKeyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Integrations.RotateKey, as: RotateKeyTask

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

    test "--new-key=<value> parses through" do
      assert {:ok, opts} = RotateKeyTask.parse_args(["--new-key=abc123"])
      assert Keyword.get(opts, :new_key) == "abc123"
    end

    test "a misspelled flag is REJECTED, not silently ignored" do
      # This is the exact scenario the round-1 review flagged as the most
      # dangerous finding: with non-strict OptionParser parsing, "--dryrun"
      # (missing hyphen) used to be accepted as an unrelated boolean flag
      # under its own wrong key, `dry_run` silently stayed `false`, and the
      # task ran a REAL rotation instead of the dry run the caller typed
      # this flag to get. `strict:` must turn this into a parse error.
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
      # Round-1 review fixed this by treating "" like the flag was never
      # passed (generate a fresh secret). Round-2 review flagged that fix
      # itself as risky: `--new-key="$MAYBE_UNSET"` with an empty variable
      # would silently rotate under a RANDOM key the caller never chose,
      # printed to stdout exactly once — unrecoverable if that output isn't
      # captured. An explicitly-empty value the caller DID pass must be
      # rejected, the same way a misspelled flag is, not quietly replaced.
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
end
