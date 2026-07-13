defmodule PhoenixKit.Utils.JsonTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Json

  describe "encode_pretty!/1" do
    test "indents nested maps and lists with 2 spaces" do
      assert Json.encode_pretty!(%{"a" => 1}) == "{\n  \"a\": 1\n}"

      assert Json.encode_pretty!(%{"a" => [1, 2]}) ==
               "{\n  \"a\": [\n    1,\n    2\n  ]\n}"
    end

    test "renders empty maps and lists compactly, not as multi-line" do
      assert Json.encode_pretty!(%{}) == "{}"
      assert Json.encode_pretty!([]) == "[]"

      assert Json.encode_pretty!(%{"empty" => %{}, "list" => []}) ==
               "{\n  \"empty\": {},\n  \"list\": []\n}"
    end

    test "output round-trips through JSON.decode!/1 back to the original term" do
      term = %{
        "path" => "/about",
        "nested" => %{"a" => 1, "b" => [1, "two", nil, true, %{"c" => 3.5}]},
        "empty_list" => [],
        "empty_map" => %{}
      }

      assert term |> Json.encode_pretty!() |> JSON.decode!() == term
    end

    test "atom keys are stringified, matching JSON.encode!/1's own behavior" do
      assert Json.encode_pretty!(%{key: "value"}) == "{\n  \"key\": \"value\"\n}"
    end
  end
end
