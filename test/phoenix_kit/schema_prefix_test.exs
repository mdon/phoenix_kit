defmodule PhoenixKit.SchemaPrefixTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support.

  Every table-backed schema must `use PhoenixKit.SchemaPrefix` so its
  queries target the schema the migrations installed into. A schema
  missing it silently falls back to `search_path` resolution — invisible
  on public installs, broken on prefixed ones.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        content = File.read!(path)

        String.contains?(content, ~s[schema "phoenix_kit]) and
          not String.contains?(content, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  # compile_env can't be read inside a function; the test build sets no
  # prefix, so this must match what the schemas compiled against.
  @compiled_prefix Application.compile_env(:phoenix_kit, :prefix)

  test "schema prefix reflects the compiled :phoenix_kit, :prefix config" do
    for schema <- [
          PhoenixKit.Users.Auth.User,
          PhoenixKit.Settings.Setting,
          PhoenixKit.Modules.Storage.File
        ] do
      assert schema.__schema__(:prefix) == @compiled_prefix
    end
  end
end
