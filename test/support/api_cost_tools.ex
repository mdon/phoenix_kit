defmodule PhoenixKit.Test.ApiCostTools do
  @moduledoc """
  A second stand-in for a PhoenixKit module that declares API tools, for the
  tests of the per-tool `cost` field. It is not part of
  `PhoenixKit.Test.ApiTools`, so the tool lists those tests assert are
  unchanged; a test registers it with `ModuleRegistry.register/1` and
  unregisters it in `on_exit`.

  | Tool | Audience | Scope / permission | Cost |
  |---|---|---|---|
  | `testkit.costly_read` | admin | `testkit.items:read` / `dashboard` | fixed `5` |
  | `testkit.batch_read` | admin | `testkit.items:read` / `dashboard` | `{__MODULE__, :queries}`: one unit per entry of `queries` |
  | `testkit.costly_write` | admin | `testkit.items:write` / `settings` | fixed `2` (a write with an `items` list: the default rule would say `ceil(rows / 50)`) |
  | `testkit.public_batch` | public | none | `{__MODULE__, :queries}` |
  """

  alias PhoenixKit.API.Tool

  @read %{read_only: true, destructive: false, idempotent: true, open_world: false}
  @write %{read_only: false, destructive: false, idempotent: false, open_world: false}

  def module_key, do: "api_cost_test_tools"
  def module_name, do: "API cost test tools"
  def enabled?, do: true

  def api_tools do
    [
      tool(
        "testkit.costly_read",
        :admin,
        "testkit.items:read",
        "dashboard",
        @read,
        :ok_result,
        5,
        %{
          "limit" => %{"type" => "integer"}
        }
      ),
      tool(
        "testkit.batch_read",
        :admin,
        "testkit.items:read",
        "dashboard",
        @read,
        :ok_result,
        {__MODULE__, :queries},
        %{"queries" => %{"type" => "array", "items" => %{"type" => "object"}}}
      ),
      tool(
        "testkit.costly_write",
        :admin,
        "testkit.items:write",
        "settings",
        @write,
        :ok_result,
        2,
        %{
          "items" => %{"type" => "array", "items" => %{"type" => "object"}}
        }
      ),
      tool(
        "testkit.public_batch",
        :public,
        nil,
        nil,
        @read,
        :ok_result,
        {__MODULE__, :queries},
        %{
          "queries" => %{"type" => "array", "items" => %{"type" => "object"}}
        }
      )
    ]
  end

  defp tool(name, audience, scope, permission, annotations, handler, cost, properties) do
    Tool.new!(
      name: name,
      audience: audience,
      scope: scope,
      permission: permission,
      title: name,
      description: "Test tool #{name}.",
      input_schema: %{
        "type" => "object",
        "properties" => properties,
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object"},
      handler: {__MODULE__, handler},
      annotations: annotations,
      cost: cost
    )
  end

  # --- cost functions: they receive the RAW, unvalidated input ----------------

  @doc "One unit per query; 1 for anything that is not a list of queries."
  def queries(%{"queries" => queries}) when is_list(queries), do: max(length(queries), 1)
  def queries(_input), do: 1

  def raises(_input), do: raise("cost function failure")
  def throws(_input), do: throw(:cost_function_failure)
  def zero(_input), do: 0
  def negative(_input), do: -4
  def a_float(_input), do: 2.5
  def a_string(_input), do: "3"
  def huge(_input), do: 5_000

  # --- handlers --------------------------------------------------------------

  def ok_result(input, _ctx),
    do: {:ok, %{"ok" => true, "keys" => input |> Map.keys() |> Enum.sort()}}
end
