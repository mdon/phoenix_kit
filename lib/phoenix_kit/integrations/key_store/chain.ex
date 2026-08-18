defmodule PhoenixKit.Integrations.KeyStore.Chain do
  @moduledoc """
  Keeps the encryption secret in more than one place at once.

  This is what makes a remote store an *addition* rather than a foundation.
  Configure the local file first and something remote second, and the secret is
  written to both while every read is served by the local one:

      config :phoenix_kit,
        integrations_key_store:
          {PhoenixKit.Integrations.KeyStore.Chain,
           stores: [
             PhoenixKit.Integrations.KeyStore.File,
             {PhoenixKit.Integrations.KeyStore.S3, bucket: "my-ops-bucket"}
           ]}

  A PhoenixKit install that wants nothing remote configures nothing and loses
  nothing: the file store on its own remains the default and the whole feature
  is opt-in. Requiring an AWS account before someone can use integrations at all
  would be the wrong shape, and this is the shape that avoids it.

  ## Reading

  The first store that has the secret answers. A later store answering when an
  earlier one did not is the recovery case — the local file was lost and the
  remote copy saved it — so it is reported at `:warning` rather than passing
  silently: the operator should know the primary is empty before the remote one
  is also gone.

  ## Writing

  Every store is written, and the read-back verification in
  `PhoenixKit.Integrations.KeyStore.write_verified/1` then checks the chain,
  which by definition checks the first store. A failure in **any** store is
  reported: a backup that quietly stopped being written is not a backup, and
  finding out during a recovery is finding out too late.

  ## What this deliberately does not do

  It does not fall back to a later store on *write* failure, and it does not
  hide a partial success behind an `:ok`. Both would produce the single
  situation this whole area exists to prevent — believing the secret is safe
  somewhere it is not.
  """

  @behaviour PhoenixKit.Integrations.KeyStore

  require Logger

  alias PhoenixKit.Integrations.KeyStore

  @impl true
  def read(opts) do
    opts
    |> stores()
    |> read_in_order([])
  end

  # `skipped` carries every store passed over, whether it was empty or failed.
  # Both matter: an empty primary means the local copy is GONE, which is the
  # recovery case this chain exists for and the one an operator most needs to
  # hear about.
  defp read_in_order([], skipped) do
    case Enum.filter(skipped, &match?({_module, {:error, _}}, &1)) do
      [] ->
        :not_configured

      [{module, {:error, reason}} | _] ->
        # Nothing had it, but something failed on the way: report the failure
        # rather than "nothing stored yet". They lead to opposite actions — one
        # invites writing a new secret, the other must not.
        {:error, {:chain_read_failed, module, reason}}
    end
  end

  defp read_in_order([{module, store_opts} | rest], skipped) do
    case KeyStore.invoke_store(module, :read, [store_opts]) do
      {:ok, secret} ->
        warn_if_recovered(module, skipped)
        {:ok, secret}

      :not_configured ->
        read_in_order(rest, skipped ++ [{module, :not_configured}])

      {:error, reason} ->
        read_in_order(rest, skipped ++ [{module, {:error, reason}}])
    end
  end

  # Answered by something other than the first store: the primary copy is gone
  # or unreadable and this read is running on a spare. Silence here would let a
  # site run indefinitely on its last remaining copy.
  defp warn_if_recovered(_module, []), do: :ok

  defp warn_if_recovered(module, skipped) do
    detail =
      Enum.map_join(skipped, ", ", fn
        {m, :not_configured} -> "#{inspect(m)} had nothing"
        {m, {:error, reason}} -> "#{inspect(m)} failed (#{inspect(reason)})"
      end)

    Logger.warning(
      "[PhoenixKit.Integrations] The encryption secret was served by #{inspect(module)}, not by " <>
        "the first store in the chain: #{detail}. This read is running on a spare copy — " <>
        "repair the primary before this one is the only copy left."
    )

    :ok
  end

  @impl true
  def write(secret, opts) do
    results =
      for {module, store_opts} <- stores(opts) do
        {module, KeyStore.invoke_store(module, :write, [secret, store_opts])}
      end

    case Enum.reject(results, fn {_module, result} -> result == :ok end) do
      [] -> :ok
      failures -> {:error, {:chain_write_failed, failures}}
    end
  end

  @impl true
  def preflight(opts) do
    results =
      for {module, store_opts} <- stores(opts) do
        {module, KeyStore.invoke_store(module, :preflight, [store_opts])}
      end

    case Enum.reject(results, fn {_module, result} -> result == :ok end) do
      [] -> :ok
      failures -> {:error, {:chain_preflight_failed, failures}}
    end
  end

  @impl true
  def describe(opts) do
    opts
    |> stores()
    |> Enum.map_join(", then ", fn {module, store_opts} ->
      KeyStore.invoke_store(module, :describe, [store_opts])
      |> case do
        location when is_binary(location) -> location
        _ -> inspect(module)
      end
    end)
  end

  @doc """
  The configured members, normalised to `{module, opts}`.

  An empty chain is a configuration mistake, not a working "store nothing"
  state, and the callbacks above report it as such rather than pretending to
  have saved something.
  """
  @spec stores(keyword()) :: [{module(), keyword()}]
  def stores(opts) do
    opts
    |> Keyword.get(:stores, [])
    |> Enum.map(fn
      {module, store_opts} when is_atom(module) and is_list(store_opts) -> {module, store_opts}
      module when is_atom(module) -> {module, []}
    end)
  end
end
