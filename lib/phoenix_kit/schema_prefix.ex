defmodule PhoenixKit.SchemaPrefix do
  @moduledoc """
  Applies the configured schema prefix to a PhoenixKit Ecto schema.

  `use PhoenixKit.SchemaPrefix` sets `@schema_prefix` from

      config :phoenix_kit, prefix: "myschema"

  so every query, insert, preload, join, and bulk operation built on the
  schema targets the named Postgres schema the migrations installed into
  — without the host having to point the database role's `search_path`
  at it. When no prefix is configured (the default `public` install),
  `@schema_prefix` stays unset and behavior is unchanged.

  This is **compile-time** configuration (read via
  `Application.compile_env/2` while the host compiles phoenix_kit):
  set it in `config/config.exs`, not `runtime.exs`. Mix tracks the value
  and recompiles the schemas when it changes. That matches the nature of
  the setting — an install's schema prefix is fixed at `mix
  phoenix_kit.install --prefix ...` time and never changes at runtime.

  Every table-backed schema in PhoenixKit must `use` this module right
  after `use Ecto.Schema` (a conformance test enforces it). Embedded
  schemas don't need it.
  """

  defmacro __using__(_opts) do
    quote do
      @schema_prefix Application.compile_env(:phoenix_kit, :prefix)
    end
  end
end
