defmodule PhoenixKit.API.ToolDangerTest do
  @moduledoc "`Tool.new/1` accepts the three declarations of `danger` and refuses everything else."
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Tool

  def noop(_input, _ctx), do: {:ok, %{}}

  defp attrs(danger),
    do: [name: "demo.write_item", audience: :public, handler: {__MODULE__, :noop}, danger: danger]

  test "nil, :always and {module, function} are accepted" do
    for ok <- [nil, :always, {__MODULE__, :noop}] do
      assert {:ok, %Tool{danger: ^ok}} = Tool.new(attrs(ok)), inspect(ok)
    end
  end

  test "a tool built without the field is not dangerous by declaration" do
    assert %Tool{danger: nil} =
             Tool.new!(name: "demo.write_item", audience: :public, handler: {__MODULE__, :noop})
  end

  test "anything else is refused, the typo :allways first" do
    for bad <- [
          :allways,
          "always",
          true,
          false,
          1,
          [:always],
          {__MODULE__},
          {nil, :noop},
          {__MODULE__, nil},
          {"m", "f"},
          %{}
        ] do
      assert {:error, messages} = Tool.new(attrs(bad)), inspect(bad)
      assert Enum.any?(messages, &(&1 =~ "danger must be")), inspect(bad)
    end
  end

  test "new!/1 raises for it" do
    assert_raise ArgumentError, ~r/danger must be/, fn -> Tool.new!(attrs(:allways)) end
  end
end
