defmodule PhoenixKit.API.RegexCompileCountTest do
  @moduledoc """
  How often the API compiles regular expressions. The count is taken by tracing
  `Regex.compile/2`, a global trace pattern, so this file is `async: false`: no other
  test module runs while it does.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.Validator

  # Counts the calls to Regex.compile/2 that `fun` makes in this process.
  defp count_regex_compiles(fun) do
    tracer =
      start_supervised!(%{
        id: :regex_tracer,
        restart: :temporary,
        start: {Task, :start_link, [fn -> tracer_loop(0) end]}
      })

    :erlang.trace_pattern({Regex, :compile, 2}, true, [:global])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Regex, :compile, 2}, false, [:global])
    end

    send(tracer, {:report, self()})

    receive do
      {:compiles, count} -> count
    end
  end

  defp tracer_loop(count) do
    receive do
      {:trace, _pid, :call, {Regex, :compile, _args}} -> tracer_loop(count + 1)
      {:report, from} -> send(from, {:compiles, count})
    end
  end

  test "a pattern is compiled once per validate call, not once per string" do
    schema = %{"type" => "array", "items" => %{"type" => "string", "pattern" => "^a"}}

    input = List.duplicate("abc", 1_000)

    assert count_regex_compiles(fn -> assert {:ok, _} = Validator.validate(schema, input) end) ==
             1
  end

  test "the schema check of a tool is done once per distinct schema, not on every validation" do
    # A pattern no other test uses, so the first check cannot have been cached by one of them.
    schema = %{
      "properties" => %{"code" => %{"type" => "string", "pattern" => "^cache-test-\\d+$"}}
    }

    tool =
      Tool.new!(
        name: "catalogue.list_products",
        audience: :admin,
        scope: "catalogue.products:read",
        permission: "catalogue",
        handler: {Kernel, :inspect},
        input_schema: schema
      )

    assert count_regex_compiles(fn -> assert {:ok, _} = Tool.validate(tool) end) == 0

    assert count_regex_compiles(fn ->
             for _ <- 1..5, do: assert({:ok, _} = Tool.validate(tool))
           end) == 0
  end

  test "a schema that failed the check keeps failing from the cache" do
    bad = %{"properties" => %{"code" => %{"type" => "string", "pattern" => "(cache-test-bad"}}}

    tool = %Tool{
      name: "catalogue.list_products",
      audience: :admin,
      scope: "catalogue.products:read",
      permission: "catalogue",
      title: "t",
      description: "",
      handler: {Kernel, :inspect},
      input_schema: bad
    }

    for _ <- 1..3 do
      assert {:error, [message]} = Tool.validate(tool)
      assert message =~ "input_schema.properties.code.pattern is not a valid regular expression"
    end

    assert count_regex_compiles(fn -> assert {:error, _} = Tool.validate(tool) end) == 0
  end
end
