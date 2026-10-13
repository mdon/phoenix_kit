defmodule PhoenixKit.Test.LanguageSettings do
  @moduledoc """
  Primes the settings cache with a language configuration, so a test without a
  database can model a configured site.

  With nothing configured the multi-language switch reads as off, which is
  single-language mode: no URL carries a locale segment. A test that is about
  locale segments therefore has to switch multi-language support on — that is
  what `multilingual!/1` is for.

  Call from `setup` in an `async: false` module (the cache is a globally named
  process). `get_setting_cached/2` consults the cache before the database, so a
  primed key reads exactly as a stored one; with a reachable database the
  calling test still checks out a sandbox connection so that a cache miss does
  not log an ownership error.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Starts the settings cache. Returns `:ok`.
  """
  def start_cache! do
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    :ok
  end

  @doc """
  Starts the cache and switches multi-language support on.

  Options:

    * `:languages` — codes to configure, the first one is the default
      (default: none, which leaves `languages_config` unset)
    * `:no_prefix` — the `default_language_no_prefix` value (default: `false`)
  """
  def multilingual!(opts \\ []) do
    start_cache!()
    put("languages_enabled", "true")
    put("default_language_no_prefix", to_string(Keyword.get(opts, :no_prefix, false)))

    case Keyword.get(opts, :languages, []) do
      [] -> :ok
      codes -> put_languages(codes)
    end
  end

  @doc """
  Starts the cache and leaves multi-language support off. `:languages` stores a
  configuration anyway — the switch keeps it while off.
  """
  def single_language!(opts \\ []) do
    start_cache!()
    put("languages_enabled", "false")

    case Keyword.get(opts, :languages, []) do
      [] -> :ok
      codes -> put_languages(codes)
    end
  end

  @doc "Stores `codes` as `languages_config`, the first one marked default."
  def put_languages([default | _] = codes) do
    languages =
      Enum.map(codes, fn code ->
        %{"code" => code, "name" => code, "is_enabled" => true, "is_default" => code == default}
      end)

    put("languages_config", %{"languages" => languages})
  end

  defp put(key, value), do: PhoenixKit.Cache.put(:settings, key, value)
end
