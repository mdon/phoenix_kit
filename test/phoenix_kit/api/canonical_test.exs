defmodule PhoenixKit.API.CanonicalTest do
  @moduledoc """
  `PhoenixKit.API.Canonical`: the same arguments hash the same whatever the order of
  their keys, different arguments, tools or list orders hash differently.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Canonical

  test "key order does not matter at any depth" do
    a = %{"ids" => ["x", "y"], "options" => %{"b" => 1, "a" => %{"d" => true, "c" => nil}}}
    b = %{"options" => %{"a" => %{"c" => nil, "d" => true}, "b" => 1}, "ids" => ["x", "y"]}

    assert Canonical.hash("t.tool", a) == Canonical.hash("t.tool", b)
  end

  test "list order matters" do
    refute Canonical.hash("t.tool", %{"ids" => ["x", "y"]}) ==
             Canonical.hash("t.tool", %{"ids" => ["y", "x"]})
  end

  test "values matter, and so do types" do
    base = Canonical.hash("t.tool", %{"n" => 1})
    refute base == Canonical.hash("t.tool", %{"n" => 2})
    refute base == Canonical.hash("t.tool", %{"n" => "1"})
    refute base == Canonical.hash("t.tool", %{"n" => true})
    refute Canonical.hash("t.tool", %{"n" => nil}) == Canonical.hash("t.tool", %{})
  end

  test "the tool name is part of the hash" do
    refute Canonical.hash("a.one", %{"n" => 1}) == Canonical.hash("a.two", %{"n" => 1})
  end

  test "the hash is 64 lowercase hex characters" do
    assert Canonical.hash("t.tool", %{}) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "strings with quotes, unicode and control characters are encoded safely" do
    input = %{"name" => "He said \"hi\"\n\t\\ \u0000 Ünï ✓"}
    assert Canonical.hash("t.tool", input) == Canonical.hash("t.tool", input)
    assert IO.iodata_to_binary(Canonical.encode(input)) |> JSON.decode!() == input
  end

  test "encode/1 produces JSON with sorted keys" do
    assert IO.iodata_to_binary(Canonical.encode(%{"b" => [1, %{"z" => 1, "a" => 2}], "a" => "x"})) ==
             ~s({"a":"x","b":[1,{"a":2,"z":1}]})
  end

  test "keys are sorted in maps too large to iterate in key order" do
    # Maps of up to 32 keys iterate in key order by themselves; larger ones iterate by hash,
    # so only these show whether `encode/1` sorts.
    keys = for n <- 1..40, do: "k" <> String.pad_leading(Integer.to_string(n), 2, "0")
    big = Map.new(keys, &{&1, 1})

    refute Map.keys(big) == keys

    expected = "{" <> Enum.map_join(keys, ",", &~s("#{&1}":1)) <> "}"
    assert IO.iodata_to_binary(Canonical.encode(big)) == expected
    assert IO.iodata_to_binary(Canonical.encode(%{"outer" => big})) == ~s({"outer":#{expected}})
  end

  test "atom keys and string keys are the same key" do
    assert Canonical.hash("t.tool", %{ids: [1]}) == Canonical.hash("t.tool", %{"ids" => [1]})
  end
end
