defmodule Mix.Tasks.PhoenixKit.BodyGuardWiringTest do
  @moduledoc """
  The BodyGuard installer step has to run on `mix phoenix_kit.update`, not
  only on `mix phoenix_kit.install`: a host that is already installed gets
  its endpoint patched by `update` or never. `update` once ran only
  `EndpointIntegration.add_pdfjs_static_mount/1` and none of
  `add_endpoint_integration/1`, so wiring the new step into the install
  pipeline alone would have reached no existing host.

  The tasks are not run here (they configure a whole project); the test reads
  the `igniter/1` callback of each and looks for the call.
  """
  use ExUnit.Case, async: true

  @tasks [
    {"lib/mix/tasks/phoenix_kit.install.ex", "install"},
    {"lib/mix/tasks/phoenix_kit.update.ex", "update"}
  ]

  # Remote calls `EndpointIntegration.<fun>` made inside `def igniter(igniter)`.
  defp endpoint_calls(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:igniter, _, [_]}, [do: body]]} = node, acc -> {node, calls_in(body) ++ acc}
        node, acc -> {node, acc}
      end)

    calls
  end

  defp calls_in(body) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:EndpointIntegration]}, fun]}, _, _} = node, acc ->
          {node, [fun | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  for {path, task} <- @tasks do
    test "mix phoenix_kit.#{task} runs EndpointIntegration.add_body_guard/1" do
      assert :add_body_guard in endpoint_calls(unquote(path))
    end
  end

  test "update keeps its other endpoint step" do
    assert :add_pdfjs_static_mount in endpoint_calls("lib/mix/tasks/phoenix_kit.update.ex")
  end
end
