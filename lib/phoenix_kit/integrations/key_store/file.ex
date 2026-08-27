defmodule PhoenixKit.Integrations.KeyStore.File do
  @moduledoc """
  Default `PhoenixKit.Integrations.KeyStore`: one file, mode `0600`, outside
  the repository.

  Chosen because it works for *every* PhoenixKit user. A cloud secrets manager
  is a better vault and a worse default — it needs an account, credentials and
  a network, none of which a person running PhoenixKit on a single box has any
  reason to own. Hosts that do have one implement the behaviour themselves.

  ## Where the file goes

  In precedence order:

    1. `:path` in the store options;
    2. `PHOENIX_KIT_INTEGRATIONS_KEY_FILE`;
    3. `~/.config/phoenix_kit/<app>-integrations.key`, where `<app>` is the
       host application — so two sites sharing a machine get separate keys
       rather than silently sharing one.

  ## Refusing to write inside a repository

  A path inside a git working tree is rejected outright. The whole failure this
  guards against is a secret reaching a repository, and "the operator will
  remember to gitignore it" is not a guarantee — a secret committed once is
  compromised even after it is deleted, because history keeps it. Outside a
  repository (a release directory, `/etc`, a home directory) the check does not
  apply and does not get in the way.

  ## Permissions

  Written `0600` in a directory created `0700`. On read, wider permissions are
  reported through `Logger.warning` — but the secret is still returned: refusing
  to decrypt would take a running application down over a permission bit, which
  is a worse outcome than a loud warning. The warning names the path and the
  mode, never the contents.
  """

  @behaviour PhoenixKit.Integrations.KeyStore

  require Logger

  @env_var "PHOENIX_KIT_INTEGRATIONS_KEY_FILE"
  @file_mode 0o600
  @dir_mode 0o700

  @impl true
  def read(opts) do
    path = path(opts)

    case File.read(path) do
      {:ok, contents} ->
        warn_if_permissive(path)
        interpret(String.trim(contents), path)

      {:error, :enoent} ->
        :not_configured

      {:error, reason} ->
        {:error, {:unreadable, path, reason}}
    end
  end

  # An empty or whitespace-only file is NOT "no secret yet". It is a file that
  # exists and holds nothing, which is what a truncated or half-finished write
  # looks like — exactly the shape of the incident this module was written
  # after, where the file looked intact and the value inside was empty.
  # Reporting it as `:not_configured` would invite a caller to overwrite it and
  # call that success.
  defp interpret("", path), do: {:error, {:empty, path}}
  defp interpret(secret, _path), do: {:ok, secret}

  @impl true
  def write(secret, opts) when is_binary(secret) do
    path = path(opts)

    with :ok <- refuse_inside_repository(path),
         :ok <- ensure_dir(path) do
      atomic_write(path, secret)
    end
  end

  @impl true
  def preflight(opts) do
    path = path(opts)

    with :ok <- refuse_inside_repository(path),
         :ok <- ensure_dir(path) do
      probe(path)
    end
  end

  @impl true
  def describe(opts), do: path(opts)

  @doc "The resolved path, for tests and operator-facing messages."
  @spec path(keyword()) :: String.t()
  def path(opts) do
    (opts[:path] || System.get_env(@env_var) || default_path())
    |> Path.expand()
  end

  defp default_path do
    app = PhoenixKit.Config.get_parent_app() || :phoenix_kit
    Path.join([home(), ".config", "phoenix_kit", "#{app}-integrations.key"])
  end

  # System.user_home/0 returns nil under some service managers (no HOME in the
  # environment). Falling back keeps the default usable instead of raising at
  # config time, and the path is still outside any repository.
  defp home, do: System.user_home() || "/var/lib/phoenix_kit"

  # Writes to a temp file in the same directory, flushes it to disk, then
  # renames. Three properties, each load-bearing:
  #
  #   * the temp file is created EMPTY and chmod'ed to 0600 before the secret is
  #     written into it. `File.write/2` creates by umask — 0644 on a default
  #     system — which would leave the secret world-readable for the window
  #     between write and chmod;
  #   * `:file.sync/1` on the file and on the directory before/after the rename.
  #     A rename is atomic with respect to ordering, not with respect to power
  #     loss: without the flush the file can survive a crash existing and empty,
  #     which is exactly the shape of the incident this module was written after
  #     ("the file looked intact and the value inside was empty"). Read-back
  #     verification does not catch it either — that read is served from page
  #     cache;
  #   * a rename replaces a symlink at `path` with a regular file, so a
  #     pre-planted symlink cannot redirect the secret elsewhere.
  defp atomic_write(path, secret) do
    tmp = path <> ".tmp"

    with :ok <- write_private(tmp, secret),
         :ok <- File.rename(tmp, path),
         :ok <- sync_dir(Path.dirname(path)) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, path, reason}}
    end
  end

  defp write_private(tmp, secret) do
    # Start from a clean slate: `:exclusive` refuses to open an existing file,
    # which also rejects a temp path someone else planted.
    File.rm(tmp)

    case :file.open(tmp, [:write, :binary, :exclusive]) do
      {:ok, fd} ->
        result =
          with :ok <- File.chmod(tmp, @file_mode),
               :ok <- :file.write(fd, secret) do
            :file.sync(fd)
          end

        :file.close(fd)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Renaming into a directory is only durable once the directory entry itself is
  # flushed. Not every platform lets a directory be opened for reading; where it
  # cannot, the file-level sync above is what we get, and failing the whole
  # write over it would be worse than the residual risk.
  defp sync_dir(dir) do
    case :file.open(dir, [:read]) do
      {:ok, fd} ->
        _ = :file.sync(fd)
        :file.close(fd)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp ensure_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok ->
        # Best effort: a pre-existing directory may be owned by someone else,
        # and failing to tighten it is not a reason to refuse to store the key.
        _ = File.chmod(dir, @dir_mode)
        :ok

      {:error, reason} ->
        {:error, {:dir_unwritable, dir, reason}}
    end
  end

  # Writes and removes a probe file next to the real one. Deliberately not the
  # real path: a pre-flight must never truncate a secret that is already there.
  defp probe(path) do
    probe_path = path <> ".preflight"

    case File.write(probe_path, "") do
      :ok ->
        # A probe that cannot be removed means the directory is writable but not
        # cleanable, which is worth saying rather than leaving litter behind.
        case File.rm(probe_path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:probe_not_removable, probe_path, reason}}
        end

      {:error, reason} ->
        {:error, {:not_writable, path, reason}}
    end
  end

  defp refuse_inside_repository(path) do
    if inside_repository?(path) do
      {:error, {:inside_repository, path}}
    else
      :ok
    end
  end

  # Walks up from the file's directory looking for a `.git` entry. `.git` is a
  # directory in a normal clone and a FILE inside a worktree, so both are
  # checked — a worktree is still a working tree, and a secret written there is
  # just as committable.
  defp inside_repository?(path) do
    path
    |> Path.dirname()
    |> resolve_symlinks()
    |> ancestors()
    |> Enum.any?(&File.exists?(Path.join(&1, ".git")))
  end

  # `Path.expand/1` is purely lexical, so `/safe/dir -> /repo/sub` would pass a
  # check made on the written path while the file lands inside the working tree
  # anyway. Resolve each component instead. Deliberately NOT `File.cd/1`: the
  # working directory is global to the VM, and a library that moves it out from
  # under unrelated processes to answer a question has traded one bug for a
  # worse one.
  #
  # Resolves one link per component, which covers a symlinked directory in the
  # path. A chain of links pointing at further links is not followed; that is a
  # deliberate stopping point rather than an unbounded loop.
  defp resolve_symlinks(dir) do
    dir
    |> Path.split()
    |> Enum.reduce("", fn segment, parent ->
      joined = if parent == "", do: segment, else: Path.join(parent, segment)

      case File.read_link(joined) do
        {:ok, target} ->
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, parent)

        {:error, _} ->
          joined
      end
    end)
  end

  defp ancestors(dir) do
    Stream.unfold(dir, fn
      nil -> nil
      current -> {current, next_ancestor(current)}
    end)
    |> Enum.to_list()
  end

  defp next_ancestor(current) do
    parent = Path.dirname(current)
    if parent == current, do: nil, else: parent
  end

  # Once per path per VM. Reads happen per credential field and read failures are
  # deliberately not cached, so warning on every read turns one misconfigured
  # file into pages of identical log lines — which is how a real warning gets
  # scrolled past.
  defp warn_if_permissive(path) do
    key = {__MODULE__, :perm_warned, path}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      do_warn_if_permissive(path)
    end

    :ok
  end

  defp do_warn_if_permissive(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        # Keep only the permission bits; the rest of `mode` is the file type.
        perms = Bitwise.band(mode, 0o777)

        if Bitwise.band(perms, 0o077) != 0 do
          Logger.warning(
            "[PhoenixKit.Integrations] Key file #{path} is mode #{Integer.to_string(perms, 8)} — " <>
              "readable beyond its owner. Run: chmod 600 #{path}"
          )
        end

      {:error, _} ->
        :ok
    end
  end
end
