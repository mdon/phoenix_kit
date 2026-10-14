defmodule PhoenixKit.API.ToolCostTest do
  @moduledoc """
  The per-tool `cost` field: validation in `Tool.new/1`, the price
  `Executor.cost/2` computes, and what the limiter really charges through
  `Executor.execute/4`.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.ApiCostTools

  @read "testkit.items:read"

  @base [
    name: "demo.heavy_report",
    audience: :admin,
    scope: "demo.reports:read",
    permission: "dashboard",
    handler: {Kernel, :inspect}
  ]

  defp build(attrs), do: Tool.new(Keyword.merge(@base, attrs))
  defp lines(count), do: List.duplicate(%{"sku" => "a"}, count)

  defp header(headers, name) do
    {_name, value} = Enum.find(headers, fn {key, _value} -> String.downcase(key) == name end)
    String.to_integer(value)
  end

  describe "Tool.new/1: the cost field" do
    test "defaults to nil, which keeps the default rule" do
      assert {:ok, %Tool{cost: nil}} = build([])
    end

    test "accepts a positive integer up to 1000 and a {module, function}" do
      for cost <- [1, 5, 1000, {ApiCostTools, :queries}] do
        assert {:ok, %Tool{cost: ^cost}} = build(cost: cost)
      end
    end

    test "refuses everything else, naming the field" do
      for cost <- [
            0,
            -3,
            1.5,
            "2",
            1001,
            {nil, :f},
            {ApiCostTools, nil},
            {ApiCostTools, "f"},
            {ApiCostTools, :f, 1},
            &Kernel.inspect/1,
            :queries,
            []
          ] do
        assert {:error, [message]} = build(cost: cost), inspect(cost)
        assert message =~ "cost must be"
      end
    end
  end

  describe "Executor.cost/2" do
    test "without the field the 1a rule stands" do
      {:ok, write} = build(annotations: %{read_only: false})
      {:ok, read} = build(annotations: %{read_only: true})

      assert Executor.cost(write, %{"items" => lines(120)}) == 3
      assert Executor.cost(read, %{"items" => lines(120)}) == 1
      assert Executor.cost(nil, %{"items" => lines(500)}) == 1
    end

    test "a fixed price replaces the default rule, for every audience and kind" do
      {:ok, heavy_write} = build(cost: 2, annotations: %{read_only: false})
      {:ok, heavy_read} = build(cost: 7, annotations: %{read_only: true})
      {:ok, heavy_public} = build(cost: 4, audience: :public, scope: nil, permission: nil)

      assert Executor.cost(heavy_write, %{"items" => lines(500)}) == 2
      assert Executor.cost(heavy_write, %{}) == 2
      assert Executor.cost(heavy_read, %{}) == 7
      assert Executor.cost(heavy_public, %{"lines" => lines(500)}) == 4
    end

    test "a function receives the raw input and prices it" do
      {:ok, tool} =
        build(cost: {ApiCostTools, :queries}, audience: :public, scope: nil, permission: nil)

      assert Executor.cost(tool, %{"queries" => lines(7)}) == 7
      assert Executor.cost(tool, %{"queries" => lines(20)}) == 20
      assert Executor.cost(tool, %{"queries" => []}) == 1
    end

    test "a function copes with input that was never validated" do
      {:ok, tool} = build(cost: {ApiCostTools, :queries})

      for junk <- [%{"queries" => "junk"}, %{}, "text", 5, nil, [1, 2]] do
        assert Executor.cost(tool, junk) == 1, inspect(junk)
      end
    end

    test "a function that fails or answers wrongly falls back to the default rule, with one warning" do
      {:ok, write} = build(annotations: %{read_only: false})
      default = Executor.cost(write, %{"items" => lines(120)})
      assert default == 3

      for function <- [:raises, :throws, :zero, :negative, :a_float, :a_string] do
        {:ok, tool} = build(cost: {ApiCostTools, function}, annotations: %{read_only: false})

        log =
          capture_log(fn ->
            send(self(), {:cost, Executor.cost(tool, %{"items" => lines(120)})})
          end)

        assert_received {:cost, cost}
        assert cost == default, "#{function}: expected the default #{default}, got #{cost}"
        assert log =~ "cost", "#{function} logged nothing"
        refute log =~ "cost function failure", "#{function} logged the exception message"
      end
    end

    test "a function that is not exported falls back too" do
      {:ok, tool} = build(cost: {ApiCostTools, :not_a_function})
      assert capture_log(fn -> send(self(), {:cost, Executor.cost(tool, %{})}) end) =~ "cost"
      assert_received {:cost, 1}
    end

    test "a price above 1000 is clamped to 1000" do
      {:ok, tool} = build(cost: {ApiCostTools, :huge})
      assert Executor.cost(tool, %{}) == 1000
    end
  end

  describe "Executor.execute/4: the limiter charges the declared price" do
    setup do
      setup_api()
      wait_for_window_room()
      ModuleRegistry.register(ApiCostTools)
      on_exit(fn -> ModuleRegistry.unregister(ApiCostTools) end)

      {owner, _role} = user_with(["dashboard", "settings"])
      {_key, token} = issue_key(owner, [@read, "testkit.items:write"])
      %{token: token}
    end

    defp authed(token),
      do: :post |> api_conn("/", token: token) |> Auth.call(Auth.init(audience: :admin))

    test "a fixed price is taken off the bucket in one call", %{token: token} do
      put_setting("api_admin_rate_per_min", 12)

      assert {:ok, _, first} = Executor.execute(authed(token), :admin, "testkit.costly_read", %{})

      assert {:ok, _, second} =
               Executor.execute(authed(token), :admin, "testkit.costly_read", %{})

      assert header(first, "ratelimit-remaining") - header(second, "ratelimit-remaining") == 5

      # 5 + 5 used of 12: a third call would need 15.
      assert {:error, :rate_limited, _, %{retry_after: _}, _} =
               Executor.execute(authed(token), :admin, "testkit.costly_read", %{})
    end

    test "a function-priced batch costs one unit per query", %{token: token} do
      put_setting("api_admin_rate_per_min", 10)

      assert {:ok, _, headers} =
               Executor.execute(authed(token), :admin, "testkit.batch_read", %{
                 "queries" => lines(6)
               })

      # The limiter keeps counting a refused hit (Hammer has no refund), so
      # nothing is asserted after the refusal.
      assert {:error, :rate_limited, _, _, _} =
               Executor.execute(authed(token), :admin, "testkit.batch_read", %{
                 "queries" => lines(6)
               })

      assert header(headers, "ratelimit-remaining") == 4
    end

    test "the price is taken from the unvalidated input: a refused call is charged one unit and the validator then refuses it",
         %{token: token} do
      put_setting("api_admin_rate_per_min", 10)

      assert {:error, :validation_failed, _, _, headers} =
               Executor.execute(authed(token), :admin, "testkit.batch_read", %{
                 "queries" => "junk"
               })

      assert header(headers, "ratelimit-remaining") == 9
    end

    test "a public tool with a function price charges the network bucket per query" do
      put_setting("api_public_ip_rate_per_min", 4)
      ip = unique_ip()
      public = fn -> :post |> api_conn("/", ip: ip) |> Auth.call(Auth.init(audience: :public)) end

      assert {:ok, _, _} =
               Executor.execute(public.(), :public, "testkit.public_batch", %{
                 "queries" => lines(3)
               })

      assert {:error, :rate_limited, _, %{retry_after: _}, _} =
               Executor.execute(public.(), :public, "testkit.public_batch", %{
                 "queries" => lines(3)
               })
    end

    test "a fixed price on a write replaces ceil(rows / 50)", %{token: token} do
      put_setting("api_admin_rate_per_min", 3)
      # 400 rows is a batch to confirm under the default threshold of 50; the fixture does not
      # answer a dry run, so the threshold is raised to its maximum (400 rows are below it).
      put_setting("api_confirm_batch_over", 500)

      assert {:ok, _, headers} =
               Executor.execute(authed(token), :admin, "testkit.costly_write", %{
                 "items" => lines(400)
               })

      assert header(headers, "ratelimit-remaining") == 1
    end
  end
end
