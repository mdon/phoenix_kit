defmodule PhoenixKit.API.ValidatorObjectTest do
  @moduledoc """
  `PhoenixKit.API.Validator`: `required`, `properties` and
  `additionalProperties`, with the paths they report.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator

  defp errors(schema, input) do
    assert {:error, errors} = Validator.validate(schema, input)
    errors
  end

  defp paths(errors), do: Enum.map(errors, & &1.path)

  describe "required, properties and additionalProperties" do
    @schema %{
      "type" => "object",
      "required" => ["sku", "price"],
      "properties" => %{
        "sku" => %{"type" => "string"},
        "price" => %{"type" => "number"},
        "note" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }

    test "a complete input passes unchanged" do
      input = %{"sku" => "A-1", "price" => 9.5, "note" => "x"}
      assert {:ok, ^input} = Validator.validate(@schema, input)
    end

    test "reports each missing required property by its own path" do
      errors = errors(@schema, %{"note" => "x"})

      assert Enum.sort(paths(errors)) == ["price", "sku"]
      assert Enum.all?(errors, &(&1.message == "is required"))
    end

    test "reports a property of the wrong type at its path" do
      assert [%{path: "price", message: "must be a number"}] =
               errors(@schema, %{"sku" => "A-1", "price" => "9.5"})
    end

    test "reports unknown properties when additionalProperties is false" do
      errors = errors(@schema, %{"sku" => "A-1", "price" => 1, "color" => "red", "size" => 3})

      assert paths(errors) == ["color", "size"]
      assert Enum.all?(errors, &(&1.message == "is not allowed"))
    end

    test "unknown properties pass when additionalProperties is true or absent" do
      open = Map.delete(@schema, "additionalProperties")
      assert {:ok, _} = Validator.validate(open, %{"sku" => "A", "price" => 1, "extra" => [1]})

      assert {:ok, _} =
               Validator.validate(Map.put(@schema, "additionalProperties", true), %{
                 "sku" => "A",
                 "price" => 1,
                 "extra" => [1]
               })
    end

    test "additionalProperties may be a schema for the extra properties" do
      schema = %{"type" => "object", "additionalProperties" => %{"type" => "integer"}}

      assert {:ok, _} = Validator.validate(schema, %{"a" => 1, "b" => 2})

      assert [%{path: "b", message: "must be an integer"}] =
               errors(schema, %{"a" => 1, "b" => "2"})
    end

    test "an empty required property is still present" do
      assert {:ok, _} = Validator.validate(@schema, %{"sku" => "", "price" => 0})
    end

    test "reports everything wrong at once, in a stable order" do
      errors = errors(@schema, %{"price" => "x", "zebra" => 1, "apple" => 2})

      assert Enum.map(errors, &{&1.path, &1.message}) == [
               {"sku", "is required"},
               {"apple", "is not allowed"},
               {"price", "must be a number"},
               {"zebra", "is not allowed"}
             ]
    end

    test "nested objects report dotted paths" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "price" => %{
            "type" => "object",
            "required" => ["amount"],
            "properties" => %{"amount" => %{"type" => "number"}}
          }
        }
      }

      assert [%{path: "price.amount", message: "is required"}] = errors(schema, %{"price" => %{}})
      assert [%{path: "price.amount"}] = errors(schema, %{"price" => %{"amount" => "1"}})
    end

    test "a schema written with atom keys works the same" do
      schema = %{
        type: :object,
        required: [:sku],
        properties: %{sku: %{type: "string"}},
        additionalProperties: false
      }

      assert {:ok, %{"sku" => "A"}} = Validator.validate(schema, %{"sku" => "A"})

      assert [%{path: "sku", message: "is required"}, %{path: "x", message: "is not allowed"}] =
               errors(schema, %{"x" => 1})
    end

    test "an integral float inside an object is converted too" do
      schema = %{
        "type" => "object",
        "properties" => %{"quantity" => %{"type" => "integer"}}
      }

      assert {:ok, %{"quantity" => 3}} = Validator.validate(schema, %{"quantity" => 3.0})
      assert [%{path: "quantity"}] = errors(schema, %{"quantity" => 3.5})
    end
  end

  describe "enum inside objects" do
    test "works for numbers and inside objects" do
      schema = %{"type" => "object", "properties" => %{"level" => %{"enum" => [1, 2, 3]}}}

      assert {:ok, _} = Validator.validate(schema, %{"level" => 2})
      assert [%{path: "level", allowed: [1, 2, 3]}] = errors(schema, %{"level" => 4})
    end
  end

  describe "a hostile object is cheap (the error list is capped at 100)" do
    @closed %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    defp key(prefix, n, width), do: prefix <> String.pad_leading("#{n}", width, "0")

    test "20 000 unknown keys give 100 errors, the first 100 in key order" do
      input = Map.new(1..20_000, &{key("k", &1, 5), &1})

      assert {:error, errors} = Validator.validate(@closed, input)
      assert length(errors) == 100
      assert paths(errors) == Enum.map(1..100, &key("k", &1, 5))
      assert Enum.all?(errors, &(&1.message == "is not allowed"))
    end

    test "the walk stops at the cap: a key after the 100th error is never looked at" do
      # "zzz" sorts after every "k..." key. Its schema has an unsupported type, which
      # raises if the property is ever visited, so a walk that does not halt fails here.
      schema = %{
        "type" => "object",
        "properties" => %{"zzz" => %{"type" => "never-visited"}},
        "additionalProperties" => false
      }

      input = Map.put(Map.new(1..200, &{key("k", &1, 3), &1}), "zzz", 1)

      assert {:error, errors} = Validator.validate(schema, input)
      assert length(errors) == 100
      assert paths(errors) == Enum.map(1..100, &key("k", &1, 3))

      # control: below the cap the same property is visited
      assert_raise ArgumentError, ~r/unsupported JSON Schema type/, fn ->
        Validator.validate(schema, Map.put(Map.new(1..5, &{key("k", &1, 3), &1}), "zzz", 1))
      end
    end

    test "a long key is shortened in the path, so the error is not as large as the body" do
      long = String.duplicate("k", 5_000)

      assert {:error, [%{path: path}]} = Validator.validate(@closed, %{long => 1})
      assert path == String.duplicate("k", 64) <> "..."

      nested = %{"type" => "object", "properties" => %{"a" => @closed}}

      assert {:error, [%{path: "a." <> rest}]} =
               Validator.validate(nested, %{"a" => %{long => 1}})

      assert rest == String.duplicate("k", 64) <> "..."

      # a short key, and a multi-byte key cut at a character boundary
      assert {:error, [%{path: "ab"}]} = Validator.validate(@closed, %{"ab" => 1})

      assert {:error, [%{path: multibyte}]} =
               Validator.validate(@closed, %{String.duplicate("\u00e9", 100) => 1})

      assert String.valid?(multibyte)
      assert String.ends_with?(multibyte, "...")
    end

    test "the cap holds for the whole result, across nested objects" do
      schema = %{"type" => "object", "additionalProperties" => @closed}
      input = Map.new(1..200, &{key("o", &1, 3), %{"x" => 1, "y" => 2}})

      assert {:error, errors} = Validator.validate(schema, input)
      assert length(errors) == 100
      assert hd(errors).path == "o001.x"
    end
  end
end
