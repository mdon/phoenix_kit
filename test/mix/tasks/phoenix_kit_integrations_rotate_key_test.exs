defmodule Mix.Tasks.PhoenixKit.Integrations.RotateKeyTest do
  # async: false — the chain-partial-failure tests mutate the global
  # `:phoenix_kit, :integrations_key_store` app env.
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.Integrations.RotateKey, as: RotateKeyTask
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyStore
  alias PhoenixKit.Integrations.KeyStore.Chain
  alias PhoenixKit.Integrations.KeyStore.File, as: FileKeyStore

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

  describe "wired_secret_reference/1 — the closing paragraph must match what was printed" do
    test "without --new-key, it points back at the value printed above" do
      assert RotateKeyTask.wired_secret_reference(false) =~ "the value above"
    end

    # `--new-key` skips the secret-printing block entirely (see
    # `print_unstored_success/3`'s `unless supplied?`), so this must not claim
    # a value was printed "above" that never was.
    test "with --new-key, it does not claim a value was printed above" do
      refute RotateKeyTask.wired_secret_reference(true) =~ "the value above"
      assert RotateKeyTask.wired_secret_reference(true) =~ "--new-key"
    end
  end

  describe "store_and_report/3 — a chain that partially fails" do
    defmodule AlwaysFailingStore do
      @moduledoc false
      @behaviour KeyStore

      @impl true
      def read(_opts), do: {:error, :boom}

      @impl true
      def write(_secret, _opts), do: {:error, :network_down}

      @impl true
      def preflight(_opts), do: {:error, :boom}

      @impl true
      def describe(_opts), do: "always-failing-store"
    end

    setup do
      previous = Application.get_env(:phoenix_kit, :integrations_key_store)

      dir =
        Path.join(System.tmp_dir!(), "pk_rotate_key_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn ->
        if previous do
          Application.put_env(:phoenix_kit, :integrations_key_store, previous)
        else
          Application.delete_env(:phoenix_kit, :integrations_key_store)
        end

        KeyStore.invalidate_cache()
        File.rm_rf(dir)
      end)

      path = Path.join(dir, "app.key")

      Application.put_env(
        :phoenix_kit,
        :integrations_key_store,
        {Chain, stores: [{FileKeyStore, path: path}, AlwaysFailingStore]}
      )

      KeyStore.invalidate_cache()

      {:ok, path: path}
    end

    # The exact reproduction from the reviewer's finding: a File member
    # succeeds, a second chain member always fails. The file already holds
    # the secret — it must be named as holding it, and it must NOT be called
    # "the only copy", which was the bug: the old message said both the file
    # (which has it) and "does not hold it" in the same breath.
    test "the surviving member is named as holding the secret, not called the only copy", %{
      path: path
    } do
      secret = String.duplicate("s", 40)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, ~r/FAILED to write it/, fn ->
            RotateKeyTask.store_and_report(3, secret, false)
          end
        end)

      # The chain member that succeeded really did land the secret.
      assert File.read!(path) == secret

      assert output =~ path, "the surviving store's location is not named: #{output}"
      assert output =~ secret

      # The exact old phrasing this replaces — "the only copy" alone is not a
      # safe substring to check, since the fix's own wording ("NOT the only
      # copy") contains it too.
      refute output =~ "now the only copy",
             "still calls the secret the only copy while #{path} holds it: #{output}"

      assert output =~ "NOT the only copy"
    end

    # A total chain failure (no survivors) must still get the original,
    # stronger warning — this fix must not weaken that case.
    test "a chain with no survivors is still told it holds the only copy" do
      Application.put_env(
        :phoenix_kit,
        :integrations_key_store,
        {Chain, stores: [AlwaysFailingStore]}
      )

      KeyStore.invalidate_cache()
      secret = String.duplicate("s", 40)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, ~r/storing the new secret FAILED/, fn ->
            RotateKeyTask.store_and_report(1, secret, false)
          end
        end)

      assert output =~ "now the only copy"
      assert output =~ secret
    end
  end
end
