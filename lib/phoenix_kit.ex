defmodule PhoenixKit do
  @moduledoc """
  PhoenixKit
  """

  alias PhoenixKit.Config

  @doc """
  Returns the current version of PhoenixKit.

  ## Examples

      iex> PhoenixKit.version()
      "1.3.3"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:phoenix_kit, :vsn) |> to_string()
  end

  @doc """
  Validates if PhoenixKit is properly configured.

  Checks for required configuration keys and returns a status.

  ## Examples

      iex> PhoenixKit.configured?()
      false

  """
  @spec configured?() :: boolean()
  def configured? do
    case Config.get(:repo, nil) do
      nil -> false
      _repo -> true
    end
  end

  @doc """
  Returns PhoenixKit configuration.

  ## Examples

      iex> PhoenixKit.config()
      %{ecto_repos: []}

  """
  @spec config() :: map()
  def config do
    :phoenix_kit
    |> Application.get_all_env()
    |> Enum.into(%{})
  end

  @doc """
  Final boot step — call from `Application.start/2` right after
  `Supervisor.start_link/2`.

  Picks up `:phoenix_kit_<x>` modules whose beams loaded after
  `PhoenixKit.ModuleRegistry` initialised (a `:phoenix_kit_*` dep starts
  *after* `:phoenix_kit` itself, so the registry's first scan can miss
  it), then runs every registered module's `migrate_legacy/0` callback.

  Returns the supervisor result unchanged so it composes:

      def start(_type, _args) do
        children = [...]
        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts) |> PhoenixKit.boot()
      end

  If `Supervisor.start_link/2` returned `{:error, _}`, this is a no-op —
  the error passes through unchanged.

  `mix phoenix_kit.install` and `mix phoenix_kit.update` wire this in
  automatically; existing apps can add the call manually.
  """
  @spec boot({:ok, pid()} | {:error, term()}) :: {:ok, pid()} | {:error, term()}
  def boot({:ok, _pid} = result) do
    PhoenixKit.ModuleRegistry.rescan()
    PhoenixKit.ModuleRegistry.run_all_legacy_migrations()
    result
  end

  def boot({:error, _reason} = result), do: result
end
