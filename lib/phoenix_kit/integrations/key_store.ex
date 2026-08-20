defmodule PhoenixKit.Integrations.KeyStore do
  @moduledoc """
  Where the integrations encryption secret is kept, as an extension point.

  `mix phoenix_kit.integrations.rotate_key` used to print a freshly generated
  secret exactly once and save it nowhere. An operator who lost that line lost
  every stored integration credential with it — the ciphertext stays in the
  database and nothing can read it again. This behaviour exists so the secret
  has somewhere to land.

  ## The default is deliberately boring

  `PhoenixKit.Integrations.KeyStore.File` writes one file, mode `0600`, outside
  the repository. No external service, no account, no credentials of its own —
  it works for any PhoenixKit user on any host, which a cloud secrets manager
  does not. Hosts that want Vault, AWS Secrets Manager or anything else
  implement this behaviour and configure their module instead; nothing here
  assumes the default.

  ## Configuring

      config :phoenix_kit, integrations_key_store: PhoenixKit.Integrations.KeyStore.File

      # or, with options
      config :phoenix_kit,
        integrations_key_store: {PhoenixKit.Integrations.KeyStore.File, path: "/etc/phoenix_kit/app.key"}

  Unconfigured is a supported state, not a broken one: rotation keeps its old
  print-once behaviour and says plainly that the secret was saved nowhere.

  ## Reading

  `PhoenixKit.Integrations.Encryption` consults the store when no explicit
  `:integrations_encryption_key` is configured, so a rotation followed by a
  restart needs no config edit. The read is memoised in `:persistent_term` —
  encryption runs per credential and must not hit the filesystem each time.
  Rotation invalidates that cache, and so can `invalidate_cache/0`.

  ## Secrets never travel in error terms

  Every callback returns the *path* or a reason, never the secret. A secret in
  an error tuple ends up in a log, a crash report or a support ticket, and a
  secret that reaches a log is compromised in the only sense that matters.
  """

  require Logger

  @typedoc "A store implementation plus the options it was configured with."
  @type configured :: {module(), keyword()}

  @doc """
  Reads the stored secret.

  `:not_configured` means the store has nothing yet (a first run), which is
  different from `{:error, reason}` — an existing secret that could not be
  read. Callers must not collapse the two: "no key yet" invites writing one,
  "could not read" must never lead to overwriting one.
  """
  @callback read(opts :: keyword()) :: {:ok, String.t()} | :not_configured | {:error, term()}

  @doc """
  Persists `secret`, replacing whatever was there.

  Implementations must not log the secret, and must not leave a partially
  written file behind on failure.
  """
  @callback write(secret :: String.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Checks the store can be written to, without writing the real secret.

  Called before a rotation re-encrypts anything. Rotation is the dangerous
  moment: once rows are re-encrypted, a store that then refuses the write
  leaves the operator holding a database no key opens. Finding out first turns
  that into an abort that changed nothing.
  """
  @callback preflight(opts :: keyword()) :: :ok | {:error, term()}

  @doc "Human-readable location, for operator-facing messages. Never the secret."
  @callback describe(opts :: keyword()) :: String.t()

  @cache_key {__MODULE__, :cached_secret}

  @doc """
  The configured store as `{module, opts}`, or `nil`.

  Accepts a bare module or a `{module, opts}` tuple.
  """
  @spec configured() :: configured() | nil
  def configured do
    case PhoenixKit.Config.get(:integrations_key_store) do
      {:ok, {module, opts}} when is_atom(module) and is_list(opts) -> {module, opts}
      {:ok, module} when is_atom(module) and module not in [nil, false, true] -> {module, []}
      _ -> nil
    end
  end

  @doc "Whether a store is configured at all."
  @spec configured?() :: boolean()
  def configured?, do: configured() != nil

  # Calls a host-supplied module without ever letting the secret reach an
  # exception. `apply/3` on a mistyped or unloaded module raises
  # UndefinedFunctionError, and Erlang formats such a report WITH ITS ARGUMENTS
  # — which for `write/2` is the secret itself, printed into the crash log.
  # Verified, not assumed. Only the exception's struct name is kept; its message
  # may quote arguments.
  @doc """
  Calls a store callback without letting a secret escape into an exception.

  Public because `PhoenixKit.Integrations.KeyStore.Chain` calls member stores
  and must not bypass this: `apply/3` on a mistyped or unloaded module raises,
  and Erlang formats such reports with their arguments — which for `write/2` is
  the secret.
  """
  @spec invoke_store(module(), atom(), [term()]) :: term()
  def invoke_store(module, fun, args), do: invoke(module, fun, args)

  defp invoke(module, fun, args) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:store_unavailable, module}}

      not function_exported?(module, fun, length(args)) ->
        {:error, {:store_missing_callback, module, fun, length(args)}}

      true ->
        try do
          apply(module, fun, args)
        rescue
          e -> {:error, {:store_raised, module, fun, e.__struct__}}
        catch
          kind, _ -> {:error, {:store_raised, module, fun, kind}}
        end
    end
  end

  @doc """
  Reads the secret from the configured store.

  Returns `:not_configured` both when no store is configured and when the
  configured store holds nothing yet — from a caller's point of view those are
  the same situation: there is no secret to use.
  """
  @spec read() :: {:ok, String.t()} | :not_configured | {:error, term()}
  def read do
    case configured() do
      nil -> :not_configured
      {module, opts} -> invoke(module, :read, [opts])
    end
  end

  @doc """
  Writes the secret, then reads it back and compares before reporting success.

  A write that reports `:ok` and did not land is the failure this whole module
  exists to prevent, and it is not hypothetical: a key file was lost this way
  on 2026-08-18 — the file looked intact and the value inside was empty. So the
  write is not trusted on its own word; it is verified by reading.

  `{:error, {:verification_failed, _}}` means the data may be re-encrypted
  while the secret is NOT safely stored. Callers must treat that as loud.
  """
  @spec write_verified(String.t()) :: :ok | :not_configured | {:error, term()}
  def write_verified(secret) when is_binary(secret) do
    case configured() do
      nil ->
        :not_configured

      {module, opts} ->
        with :ok <- invoke(module, :write, [secret, opts]) do
          verify_readback(module, opts, secret)
        end
    end
  end

  defp verify_readback(module, opts, secret) do
    case invoke(module, :read, [opts]) do
      {:ok, ^secret} ->
        invalidate_cache()
        :ok

      {:ok, _different} ->
        {:error, {:verification_failed, :mismatch}}

      :not_configured ->
        {:error, {:verification_failed, :absent_after_write}}

      {:error, reason} ->
        {:error, {:verification_failed, reason}}
    end
  end

  @doc """
  Runs the configured store's pre-flight check.

  `:not_configured` when there is no store — not an error; the caller decides
  whether that is acceptable.
  """
  @spec preflight() :: :ok | :not_configured | {:error, term()}
  def preflight do
    case configured() do
      nil -> :not_configured
      {module, opts} -> invoke(module, :preflight, [opts])
    end
  end

  @doc "Where the configured store keeps the secret, for messages. Never the secret."
  @spec describe() :: String.t() | nil
  def describe do
    case configured() do
      nil ->
        nil

      {module, opts} ->
        case invoke(module, :describe, [opts]) do
          location when is_binary(location) -> location
          _ -> "#{inspect(module)} (location unavailable)"
        end
    end
  end

  @doc """
  Memoised `read/0`, for the encryption hot path.

  Encryption runs once per credential field; an unmemoised read would stat and
  open a file on every one. The cache is invalidated by `invalidate_cache/0`,
  which rotation calls after storing a new secret.
  """
  @spec cached_read() :: {:ok, String.t()} | :not_configured | {:error, term()}
  def cached_read do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        result = read()
        # Only a hit is cached. Caching a failure would turn a transient
        # problem (a file briefly unreadable during deployment) into a
        # permanent one for the life of the VM.
        if match?({:ok, _}, result), do: :persistent_term.put(@cache_key, result)
        result

      cached ->
        cached
    end
  end

  @doc """
  A short description of a store error, safe to put in a log or a message.

  Deliberately NOT `inspect/1` of the whole term. The reasons produced here are
  known to be safe, but a host-supplied store returns whatever it likes from
  `read/1` and `write/2` — including, plausibly, an error that quotes the value
  it failed to store. Only the recognised shapes are formatted; anything else is
  reduced to its outermost tag, so an unknown term cannot carry a secret into a
  log by accident.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:inside_repository, path}),
    do: "#{path} is inside a git working tree; a secret must not live where it can be committed"

  def describe_error({:verification_failed, :absent_after_write}),
    do: "the write reported success but the secret was not there when read back"

  def describe_error({:verification_failed, :mismatch}),
    do: "the value read back did not match what was written"

  def describe_error({:verification_failed, reason}),
    do: "read-back failed: #{describe_error(reason)}"

  def describe_error({:empty, path}), do: "#{path} exists but is empty"
  def describe_error({:store_unavailable, module}), do: "#{inspect(module)} is not loaded"

  def describe_error({:store_missing_callback, module, fun, arity}),
    do: "#{inspect(module)} does not export #{fun}/#{arity}"

  def describe_error({:store_raised, module, fun, kind}),
    do: "#{inspect(module)}.#{fun} raised #{inspect(kind)}"

  def describe_error({:empty_chain, _module}),
    do: "the chain has no stores configured"

  # `Chain.read/1` failing is Chain's OWN failure, not a third-party store's —
  # naming it here, rather than letting it fall to the generic tuple catch-all
  # below, is what keeps the failing chain member and its reason on the
  # operator-facing message instead of behind "details withheld".
  def describe_error({:chain_read_failed, module, reason}),
    do: "chain member #{inspect(module)} failed: #{describe_error(reason)}"

  def describe_error({:chain_write_failed, failures}) when is_list(failures),
    do: "chain write failed for " <> describe_chain_failures(failures)

  def describe_error({:chain_preflight_failed, failures}) when is_list(failures),
    do: "chain pre-flight failed for " <> describe_chain_failures(failures)

  def describe_error({kind, path, reason}) when is_atom(kind) and is_binary(path),
    do: "#{kind} at #{path}: #{inspect(reason)}"

  # Unknown shape from a host-supplied store: keep the tag, drop the payload.
  def describe_error(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: "#{inspect(elem(reason, 0))} (details withheld — they came from a third-party store)"

  def describe_error(reason) when is_atom(reason), do: inspect(reason)
  def describe_error(_reason), do: "an unrecognised error (details withheld)"

  # Each entry is `{module, result}` for a chain member that did not return
  # `:ok`. Describing every one, not just the first, is why `Chain.write/2`
  # collects the whole list rather than stopping at the first failure.
  @spec describe_chain_failures([{module(), term()}]) :: String.t()
  defp describe_chain_failures(failures) do
    Enum.map_join(failures, "; ", fn
      {module, {:error, reason}} -> "#{inspect(module)} (#{describe_error(reason)})"
      {module, other} -> "#{inspect(module)} (#{inspect(other)})"
    end)
  end

  @doc "Drops the memoised secret. Safe to call when nothing is cached."
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end
end
