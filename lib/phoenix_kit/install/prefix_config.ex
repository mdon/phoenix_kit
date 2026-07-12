defmodule PhoenixKit.Install.PrefixConfig do
  @moduledoc """
  Persists the `--prefix` install option into the host's config files.

  `mix phoenix_kit.install --prefix "auth"` bakes the prefix into the
  generated migration, but the migration docs also tell hosts to set

      config :phoenix_kit, prefix: "auth"

  Without that config entry, later tooling (`mix phoenix_kit.update`,
  `mix phoenix_kit.status`) defaults to `"public"`, reports the install
  as missing, and — worst case — generates a from-scratch migration
  into the wrong schema. This module writes the config entry whenever
  a non-public prefix is used, mirroring how the repo config is added.
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Project.Config
  alias PhoenixKit.Migrations.Postgres.Helpers

  @doc """
  Resolves the effective schema prefix for phoenix_kit mix tasks.

  Order: explicit `--prefix` option → `config :phoenix_kit, :prefix` →
  `"public"`. Raises `ArgumentError` for a prefix the migration chain
  would reject anyway (empty string, uppercase, dashes, injection
  shapes) — failing at the task boundary beats failing mid-migration.
  """
  @spec resolve_prefix(keyword() | map()) :: String.t()
  def resolve_prefix(opts) do
    prefix = opts[:prefix] || configured_prefix() || "public"
    Helpers.validate_prefix!(prefix)
    prefix
  end

  defp configured_prefix do
    case Elixir.Application.get_env(:phoenix_kit, :prefix) do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> nil
    end
  end

  @doc """
  Adds `config :phoenix_kit, prefix: prefix` to config.exs and test.exs
  when installing with a non-public prefix. No-op for the default
  `"public"` prefix (or when no prefix option was given).
  """
  @spec add_prefix_configuration(term(), String.t() | nil) :: term()
  def add_prefix_configuration(igniter, prefix) when prefix in [nil, "public"], do: igniter

  def add_prefix_configuration(igniter, prefix) when is_binary(prefix) do
    # Fail at install time, not at mix ecto.migrate time — the chain
    # rejects anything outside [a-z_][a-z0-9_]* and we'd otherwise
    # persist the bad value into config + the generated migration.
    # Deliberately OUTSIDE persist_prefix_config/2's rescue: a validation
    # failure must abort, not degrade into the "add it manually" notice.
    Helpers.validate_prefix!(prefix)
    persist_prefix_config(igniter, prefix)
  end

  defp persist_prefix_config(igniter, prefix) do
    igniter
    |> Config.configure_new("config.exs", :phoenix_kit, [:prefix], prefix)
    |> Config.configure_new("test.exs", :phoenix_kit, [:prefix], prefix)
  rescue
    _ ->
      Igniter.add_notice(igniter, """
      ⚠️  Could not persist the schema prefix automatically.

      Please add this to config/config.exs (and config/test.exs):

        config :phoenix_kit, prefix: #{inspect(prefix)}

      Without it, mix phoenix_kit.update / status will look for the
      installation in the "public" schema.
      """)
  end
end
