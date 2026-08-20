defmodule PhoenixKit.Integrations.KeyStoreTest do
  # Mutates application env (the configured store), so not async.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.KeyStore
  alias PhoenixKit.Integrations.KeyStore.File, as: FileStore

  @secret "0123456789abcdef0123456789abcdef0123456789ab"

  # ExUnit's own `:tmp_dir` lives under the project (`/app/tmp/...`), which this
  # store refuses on purpose — see the "never written where it could be
  # committed" tests below. Real deployments keep the key outside the checkout,
  # so the round-trip tests use a directory outside it too.
  defp outside_tmp_dir do
    dir =
      Path.join([
        System.tmp_dir!(),
        "phoenix_kit_key_store_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :integrations_key_store)
    KeyStore.invalidate_cache()

    on_exit(fn ->
      if previous do
        Application.put_env(:phoenix_kit, :integrations_key_store, previous)
      else
        Application.delete_env(:phoenix_kit, :integrations_key_store)
      end

      KeyStore.invalidate_cache()
    end)

    :ok
  end

  defp configure(tmp_dir, extra \\ []) do
    opts = Keyword.merge([path: Path.join(tmp_dir, "integrations.key")], extra)
    Application.put_env(:phoenix_kit, :integrations_key_store, {FileStore, opts})
    opts
  end

  describe "the file store round-trips a secret" do
    test "write then read returns exactly what was written" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)

      assert :ok = FileStore.write(@secret, opts)
      assert {:ok, @secret} = FileStore.read(opts)
    end

    test "the file is mode 0600 and its directory 0700" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir, path: Path.join([tmp_dir, "nested", "integrations.key"]))

      assert :ok = FileStore.write(@secret, opts)

      path = FileStore.path(opts)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end

    test "a trailing newline from an editor does not corrupt the secret" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      File.write!(FileStore.path(opts), @secret <> "\n")

      assert {:ok, @secret} = FileStore.read(opts)
    end

    test "writing leaves no temporary file behind" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      assert :ok = FileStore.write(@secret, opts)

      refute File.exists?(FileStore.path(opts) <> ".tmp")
    end
  end

  describe "an absent secret and an unreadable one are different answers" do
    test "no file yet → :not_configured" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      assert :not_configured = FileStore.read(opts)
    end

    # The incident this module exists for: the file looked intact and the value
    # inside was empty. Reporting that as "nothing stored yet" would invite a
    # caller to overwrite it and call the overwrite a success.
    test "an empty file is an error, NOT 'nothing stored yet'" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      File.write!(FileStore.path(opts), "")

      assert {:error, {:empty, _path}} = FileStore.read(opts)
    end

    test "a whitespace-only file is treated the same way" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      File.write!(FileStore.path(opts), "   \n")

      assert {:error, {:empty, _path}} = FileStore.read(opts)
    end
  end

  describe "a secret is never written where it could be committed" do
    test "a path inside a git working tree is refused" do
      tmp_dir = outside_tmp_dir()
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      opts = [path: Path.join([tmp_dir, "priv", "secret.key"])]

      assert {:error, {:inside_repository, _}} = FileStore.write(@secret, opts)
      refute File.exists?(FileStore.path(opts))
    end

    # `.git` is a FILE, not a directory, inside a linked worktree — and a
    # worktree is still a working tree.
    test "a path inside a linked worktree is refused too" do
      tmp_dir = outside_tmp_dir()
      File.write!(Path.join(tmp_dir, ".git"), "gitdir: /elsewhere/.git/worktrees/wt\n")
      opts = [path: Path.join(tmp_dir, "secret.key")]

      assert {:error, {:inside_repository, _}} = FileStore.write(@secret, opts)
    end

    test "pre-flight refuses it as well, before any rotation starts" do
      tmp_dir = outside_tmp_dir()
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      opts = [path: Path.join(tmp_dir, "secret.key")]

      assert {:error, {:inside_repository, _}} = FileStore.preflight(opts)
    end
  end

  describe "pre-flight does not disturb an existing secret" do
    test "a successful pre-flight leaves the stored secret intact" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      :ok = FileStore.write(@secret, opts)

      assert :ok = FileStore.preflight(opts)
      assert {:ok, @secret} = FileStore.read(opts)
      refute File.exists?(FileStore.path(opts) <> ".preflight")
    end
  end

  describe "write_verified/1 confirms by reading, not by trusting the write" do
    test "a real store round-trips and reports :ok" do
      tmp_dir = outside_tmp_dir()
      configure(tmp_dir)

      assert :ok = KeyStore.write_verified(@secret)
      assert {:ok, @secret} = KeyStore.read()
    end

    test "no store configured → :not_configured, and nothing is claimed" do
      Application.delete_env(:phoenix_kit, :integrations_key_store)
      assert :not_configured = KeyStore.write_verified(@secret)
    end

    # A store whose write says :ok while nothing lands is the exact failure
    # mode being defended against, so it is tested with a store that does that.
    test "a lying store is caught by the read-back" do
      Application.put_env(:phoenix_kit, :integrations_key_store, {__MODULE__.LyingStore, []})

      assert {:error, {:verification_failed, :absent_after_write}} =
               KeyStore.write_verified(@secret)
    end

    test "a store that stores something else is caught too" do
      Application.put_env(:phoenix_kit, :integrations_key_store, {__MODULE__.WrongStore, []})

      assert {:error, {:verification_failed, :mismatch}} = KeyStore.write_verified(@secret)
    end
  end

  describe "caching" do
    test "a stored secret is memoised and invalidation picks up a new one" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      :ok = FileStore.write(@secret, opts)

      assert {:ok, @secret} = KeyStore.cached_read()

      # Change the file behind the cache: the cached value must still be served.
      File.write!(FileStore.path(opts), "second-secret-second-secret-second-secret")
      assert {:ok, @secret} = KeyStore.cached_read()

      KeyStore.invalidate_cache()
      assert {:ok, "second-secret-second-secret-second-secret"} = KeyStore.cached_read()
    end

    # Caching a failure would turn a file that is briefly unreadable during a
    # deployment into a permanently broken one for the life of the VM. The
    # earlier version of this test primed the cache with :not_configured, which
    # is not a failure at all — it asserted nothing about the branch it names.
    test "a genuine read ERROR is not cached, and recovery is picked up" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)

      # Exists and holds nothing: an error, not "nothing stored yet".
      File.write!(FileStore.path(opts), "")
      assert {:error, {:empty, _}} = KeyStore.cached_read()
      assert {:error, {:empty, _}} = KeyStore.cached_read()

      :ok = FileStore.write(@secret, opts)
      assert {:ok, @secret} = KeyStore.cached_read()
    end

    test "an absent store is not cached either" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)

      assert :not_configured = KeyStore.cached_read()

      :ok = FileStore.write(@secret, opts)
      assert {:ok, @secret} = KeyStore.cached_read()
    end
  end

  describe "configuration shapes" do
    test "a bare module is accepted" do
      Application.put_env(:phoenix_kit, :integrations_key_store, FileStore)
      assert {FileStore, []} = KeyStore.configured()
      assert KeyStore.configured?()
    end

    test "a {module, opts} tuple is accepted" do
      tmp_dir = outside_tmp_dir()
      opts = configure(tmp_dir)
      assert {FileStore, ^opts} = KeyStore.configured()
    end

    test "nothing configured → nil, and configured?/0 is false" do
      Application.delete_env(:phoenix_kit, :integrations_key_store)
      refute KeyStore.configured?()
      assert KeyStore.configured() == nil
      assert KeyStore.describe() == nil
    end
  end

  describe "the secret never travels in an error term" do
    test "no failure path carries the secret" do
      tmp_dir = outside_tmp_dir()
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      inside = [path: Path.join(tmp_dir, "secret.key")]

      errors = [
        FileStore.write(@secret, inside),
        FileStore.preflight(inside),
        FileStore.read(path: Path.join(tmp_dir, "missing.key"))
      ]

      for error <- errors do
        refute inspect(error) =~ @secret
      end
    end
  end

  defmodule LyingStore do
    @moduledoc false
    @behaviour PhoenixKit.Integrations.KeyStore

    @impl true
    def read(_opts), do: :not_configured
    @impl true
    def write(_secret, _opts), do: :ok
    @impl true
    def preflight(_opts), do: :ok
    @impl true
    def describe(_opts), do: "lying-store"
  end

  defmodule WrongStore do
    @moduledoc false
    @behaviour PhoenixKit.Integrations.KeyStore

    @impl true
    def read(_opts), do: {:ok, "something-else-entirely"}
    @impl true
    def write(_secret, _opts), do: :ok
    @impl true
    def preflight(_opts), do: :ok
    @impl true
    def describe(_opts), do: "wrong-store"
  end

  describe "a broken store module cannot leak the secret" do
    test "a module that does not exist is an error, not a crash" do
      Application.put_env(:phoenix_kit, :integrations_key_store, NoSuchKeyStoreModule)

      assert {:error, {:store_unavailable, NoSuchKeyStoreModule}} = KeyStore.read()

      assert {:error, {:store_unavailable, NoSuchKeyStoreModule}} =
               KeyStore.write_verified(@secret)
    end

    # `apply/3` on a missing function raises UndefinedFunctionError, and Erlang
    # formats that report WITH THE ARGUMENTS — for write/2 that is the secret,
    # printed straight into the crash log.
    test "the secret never appears in the error from a broken store" do
      Application.put_env(:phoenix_kit, :integrations_key_store, NoSuchKeyStoreModule)

      error = KeyStore.write_verified(@secret)
      refute inspect(error) =~ @secret
    end

    test "a store that raises is caught, and only the exception type is kept" do
      Application.put_env(:phoenix_kit, :integrations_key_store, {__MODULE__.RaisingStore, []})

      assert {:error, {:store_raised, _, :write, RuntimeError}} = KeyStore.write_verified(@secret)
      refute inspect(KeyStore.write_verified(@secret)) =~ @secret
    end

    test "a module missing a callback is reported as such" do
      Application.put_env(:phoenix_kit, :integrations_key_store, {__MODULE__.PartialStore, []})

      assert {:error, {:store_missing_callback, _, :read, 1}} = KeyStore.read()
    end

    test "false and true are not modules" do
      Application.put_env(:phoenix_kit, :integrations_key_store, false)
      refute KeyStore.configured?()
    end
  end

  describe "path resolution" do
    test "the environment variable is used when no :path option is given" do
      dir = outside_tmp_dir()
      env_path = Path.join(dir, "from-env.key")
      System.put_env("PHOENIX_KIT_INTEGRATIONS_KEY_FILE", env_path)
      on_exit(fn -> System.delete_env("PHOENIX_KIT_INTEGRATIONS_KEY_FILE") end)

      assert FileStore.path([]) == env_path
      # An explicit option still wins over the environment.
      explicit = Path.join(dir, "explicit.key")
      assert FileStore.path(path: explicit) == explicit
    end
  end

  describe "the secret is not left readable by others, even briefly" do
    # `File.write/2` creates by umask — 0644 on a default system — so a
    # write-then-chmod would leave the secret world-readable in between. The
    # invariant that matters is not "the file is never 0644" (it briefly is,
    # while still EMPTY, between :file.open and chmod) but that it is never
    # both readable by others AND holding anything.
    test "the temporary file never holds the secret while others can read it" do
      dir = outside_tmp_dir()
      opts = configure(dir)
      tmp = FileStore.path(opts) <> ".tmp"

      sampler =
        Task.async(fn ->
          Enum.reduce(1..50_000, [], fn _, acc ->
            case File.stat(tmp) do
              {:ok, %File.Stat{mode: mode, size: size}} ->
                [{Bitwise.band(mode, 0o777), size} | acc]

              _ ->
                acc
            end
          end)
        end)

      assert :ok = FileStore.write(@secret, opts)
      samples = Task.await(sampler)

      exposed =
        Enum.filter(samples, fn {perms, size} -> Bitwise.band(perms, 0o077) != 0 and size > 0 end)

      assert exposed == [],
             "the secret was readable by others while on disk: #{inspect(Enum.take(exposed, 3))}"
    end
  end

  describe "a permissive key file is reported" do
    test "wider than 0600 logs a warning naming the path, never the contents" do
      import ExUnit.CaptureLog

      dir = outside_tmp_dir()
      opts = configure(dir)
      path = FileStore.path(opts)
      File.write!(path, @secret)
      File.chmod!(path, 0o644)

      log = capture_log(fn -> assert {:ok, @secret} = FileStore.read(opts) end)

      assert log =~ "readable beyond its owner"
      assert log =~ path
      refute log =~ @secret
    end
  end

  defmodule RaisingStore do
    @moduledoc false
    @behaviour PhoenixKit.Integrations.KeyStore

    @impl true
    def read(_opts), do: :not_configured
    @impl true
    def write(_secret, _opts), do: raise("store exploded")
    @impl true
    def preflight(_opts), do: :ok
    @impl true
    def describe(_opts), do: "raising-store"
  end

  defmodule PartialStore do
    @moduledoc false
    def write(_secret, _opts), do: :ok
  end

  describe "describe_error/1 withholds what it does not recognise" do
    test "known shapes are spelled out" do
      assert KeyStore.describe_error({:empty, "/k"}) =~ "exists but is empty"
      assert KeyStore.describe_error({:verification_failed, :mismatch}) =~ "did not match"
      assert KeyStore.describe_error({:store_unavailable, Foo}) =~ "not loaded"
    end

    # A host-supplied store returns whatever it likes. An inspect/1 fallback
    # would copy an error that quotes the value it failed to store straight into
    # an operator-facing message.
    test "an unknown tuple keeps only its tag, never its payload" do
      described = KeyStore.describe_error({:some_custom_failure, @secret})

      assert described =~ "some_custom_failure"
      assert described =~ "details withheld"
      refute described =~ @secret
    end

    test "an unknown non-tuple term is withheld entirely" do
      refute KeyStore.describe_error(%{secret: @secret}) =~ @secret
    end
  end

  # `PhoenixKit.Integrations.KeyStore.Chain` is first-party, not a
  # "third-party store" — its own failure terms must be named and their
  # nested member reasons described, not swallowed by the generic
  # "details withheld" catch-all above.
  describe "describe_error/1 names Chain's own failures instead of hiding them" do
    test "an empty chain is described, not withheld" do
      described = KeyStore.describe_error({:empty_chain, PhoenixKit.Integrations.KeyStore.Chain})

      refute described =~ "third-party"
      refute described =~ "withheld"
    end

    test "chain_read_failed names the failing member and its reason" do
      described =
        KeyStore.describe_error({:chain_read_failed, PhoenixKit.Integrations.KeyStore.S3, :boom})

      refute described =~ "third-party"
      refute described =~ "withheld"
      assert described =~ "PhoenixKit.Integrations.KeyStore.S3"
    end

    test "chain_write_failed names every failing member and its reason" do
      failures = [
        {PhoenixKit.Integrations.KeyStore.File, {:error, {:empty, "/k"}}},
        {PhoenixKit.Integrations.KeyStore.S3, {:error, :boom}}
      ]

      described = KeyStore.describe_error({:chain_write_failed, failures})

      refute described =~ "third-party"
      refute described =~ "withheld"
      assert described =~ "PhoenixKit.Integrations.KeyStore.File"
      assert described =~ "exists but is empty"
      assert described =~ "PhoenixKit.Integrations.KeyStore.S3"
    end

    test "chain_preflight_failed names the failing member and its reason" do
      failures = [
        {PhoenixKit.Integrations.KeyStore.S3, {:error, {:store_unavailable, MissingModule}}}
      ]

      described = KeyStore.describe_error({:chain_preflight_failed, failures})

      refute described =~ "third-party"
      refute described =~ "withheld"
      assert described =~ "PhoenixKit.Integrations.KeyStore.S3"
      assert described =~ "not loaded"
    end

    # A chain member's result is only in `failures` because it wasn't `:ok` —
    # it is NOT guaranteed to be `{:error, reason}`. A host-supplied store
    # that breaks the behaviour contract can put anything there, including,
    # for `write/2`, the secret itself. This must never be `inspect/1`ed
    # straight into an operator-facing message (the same reasoning as the
    # generic catch-all's "details withheld").
    test "a member result that is not {:error, _} never leaks its payload" do
      failures = [{PhoenixKit.Integrations.KeyStore.S3, @secret}]

      described = KeyStore.describe_error({:chain_write_failed, failures})

      refute described =~ @secret
      assert described =~ "PhoenixKit.Integrations.KeyStore.S3"
      assert described =~ "withheld"
    end
  end

  describe "Chain keeps the secret in more than one place" do
    alias PhoenixKit.Integrations.KeyStore.Chain

    setup do
      on_exit(fn ->
        for id <- [:primary, :spare], do: :persistent_term.erase({__MODULE__.MemoryStore, id})
      end)

      :ok
    end

    defp chain(stores), do: [stores: stores]
    defp memory(id), do: {__MODULE__.MemoryStore, [id: id]}

    test "the first store that has it answers, and nothing is logged" do
      import ExUnit.CaptureLog

      __MODULE__.MemoryStore.put(:primary, @secret)
      __MODULE__.MemoryStore.put(:spare, "a-different-older-secret-value-here")

      log =
        capture_log(fn ->
          assert {:ok, @secret} = Chain.read(chain([memory(:primary), memory(:spare)]))
        end)

      refute log =~ "spare copy"
    end

    # The case the chain exists for: the local copy is gone and the remote one
    # saves the site. It must not pass silently — a site can otherwise run for
    # months on its last remaining copy.
    test "a spare answering when the primary is EMPTY is reported" do
      import ExUnit.CaptureLog

      __MODULE__.MemoryStore.put(:spare, @secret)

      log =
        capture_log(fn ->
          assert {:ok, @secret} = Chain.read(chain([memory(:primary), memory(:spare)]))
        end)

      assert log =~ "not by the first store"
      assert log =~ "had nothing"
    end

    test "a spare answering after the primary FAILED is reported too" do
      import ExUnit.CaptureLog

      __MODULE__.MemoryStore.put(:spare, @secret)

      log =
        capture_log(fn ->
          assert {:ok, @secret} =
                   Chain.read(chain([{__MODULE__.FailingStore, []}, memory(:spare)]))
        end)

      assert log =~ "not by the first store"
      assert log =~ "failed"
    end

    test "nothing anywhere → :not_configured, which invites a first write" do
      assert :not_configured = Chain.read(chain([memory(:primary), memory(:spare)]))
    end

    # An error anywhere must not be reported as "nothing stored yet": one invites
    # writing a new secret over the old one, the other must never.
    test "a failure with nothing found is an error, not :not_configured" do
      assert {:error, {:chain_read_failed, _module, _reason}} =
               Chain.read(chain([{__MODULE__.FailingStore, []}, memory(:spare)]))
    end

    test "a write goes to every store" do
      assert :ok = Chain.write(@secret, chain([memory(:primary), memory(:spare)]))

      assert {:ok, @secret} = __MODULE__.MemoryStore.read(id: :primary)
      assert {:ok, @secret} = __MODULE__.MemoryStore.read(id: :spare)
    end

    # A backup that quietly stopped being written is not a backup.
    test "one store failing fails the write and names which" do
      assert {:error, {:chain_write_failed, failures}} =
               Chain.write(@secret, chain([memory(:primary), {__MODULE__.FailingStore, []}]))

      assert [{__MODULE__.FailingStore, {:error, _}}] = failures
    end

    test "pre-flight fails if any member cannot be written" do
      assert :ok = Chain.preflight(chain([memory(:primary)]))

      assert {:error, {:chain_preflight_failed, _}} =
               Chain.preflight(chain([memory(:primary), {__MODULE__.FailingStore, []}]))
    end

    test "describe names every member in order" do
      described = Chain.describe(chain([memory(:primary), memory(:spare)]))
      assert described =~ "memory:primary"
      assert described =~ "then"
      assert described =~ "memory:spare"
    end

    test "a bare module in the list is accepted alongside {module, opts}" do
      assert [{__MODULE__.FailingStore, []}, {__MODULE__.MemoryStore, [id: :spare]}] =
               Chain.stores(stores: [__MODULE__.FailingStore, memory(:spare)])
    end

    # An empty `:stores` list is a configuration mistake (see the moduledoc's
    # "What this deliberately does not do"), not a working "store nothing"
    # state — a bare `preflight`/`write` success here is what let a rotation
    # start against a chain that would silently save nothing.
    test "an empty chain fails preflight, not :ok" do
      assert {:error, {:empty_chain, Chain}} = Chain.preflight(chain([]))
    end

    test "an empty chain fails write, not :ok" do
      assert {:error, {:empty_chain, Chain}} = Chain.write(@secret, chain([]))
    end

    test "an empty chain fails read, not :not_configured" do
      assert {:error, {:empty_chain, Chain}} = Chain.read(chain([]))
    end

    test "an empty chain's describe names it, never an empty string" do
      described = Chain.describe(chain([]))
      assert is_binary(described)
      assert described != ""
      assert described =~ "empty"
    end

    test "an absent :stores option is empty too" do
      assert {:error, {:empty_chain, Chain}} = Chain.preflight([])
    end
  end

  describe "the S3 store refuses to act without a bucket" do
    alias PhoenixKit.Integrations.KeyStore.S3

    # Every callback must fail before any network call: a store that reaches out
    # to decide it was misconfigured is slower and noisier for no gain.
    test "read, write and preflight all report the missing bucket" do
      assert {:error, {:bucket_not_configured, S3}} = S3.read([])
      assert {:error, {:bucket_not_configured, S3}} = S3.write(@secret, [])
      assert {:error, {:bucket_not_configured, S3}} = S3.preflight([])
    end

    test "describe says so rather than inventing a location" do
      assert S3.describe([]) =~ "bucket not configured"
    end

    test "describe names bucket and object when configured" do
      assert S3.describe(bucket: "ops", key: "k/secret") == "s3://ops/k/secret"
      assert S3.describe(bucket: "ops") =~ "s3://ops/phoenix_kit/"
    end

    test "no failure path carries the secret" do
      for error <- [S3.write(@secret, []), S3.read([]), S3.preflight([])] do
        refute inspect(error) =~ @secret
      end
    end
  end

  defmodule MemoryStore do
    @moduledoc false
    @behaviour PhoenixKit.Integrations.KeyStore

    def put(id, secret), do: :persistent_term.put({__MODULE__, id}, secret)

    @impl true
    def read(opts) do
      case :persistent_term.get({__MODULE__, opts[:id]}, nil) do
        nil -> :not_configured
        secret -> {:ok, secret}
      end
    end

    @impl true
    def write(secret, opts) do
      put(opts[:id], secret)
      :ok
    end

    @impl true
    def preflight(_opts), do: :ok
    @impl true
    def describe(opts), do: "memory:#{opts[:id]}"
  end

  defmodule FailingStore do
    @moduledoc false
    @behaviour PhoenixKit.Integrations.KeyStore

    @impl true
    def read(_opts), do: {:error, :boom}
    @impl true
    def write(_secret, _opts), do: {:error, :boom}
    @impl true
    def preflight(_opts), do: {:error, :boom}
    @impl true
    def describe(_opts), do: "failing"
  end
end
