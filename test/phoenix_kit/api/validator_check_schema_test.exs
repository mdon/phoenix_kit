defmodule PhoenixKit.API.ValidatorCheckSchemaTest do
  @moduledoc """
  `PhoenixKit.API.Validator.check_schema/2`: a tool schema that `validate/2`
  would silently not enforce is refused when the tool is registered.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator

  defp problems(schema) do
    assert {:error, problems} = Validator.check_schema(schema)
    problems
  end

  describe "a schema made of supported keywords" do
    test "passes, with annotations and x- extensions" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "title" => "Create product",
        "description" => "Creates one",
        "required" => ["sku"],
        "properties" => %{
          "sku" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 40,
            "pattern" => "^[A-Z0-9-]+$",
            "default" => "A-1",
            "examples" => ["A-1"],
            "x-ui" => %{"widget" => "text"}
          },
          "price" => %{"type" => ["number", "null"], "minimum" => 0, "maximum" => 1.0e6},
          "state" => %{"enum" => ["draft", "active"]},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 10},
          "any" => true
        },
        "additionalProperties" => false
      }

      assert :ok = Validator.check_schema(schema)
    end

    test "passes with the annotation `format`, at the root, in a property and in items" do
      assert :ok = Validator.check_schema(%{"type" => "string", "format" => "uuid"})

      assert :ok =
               Validator.check_schema(%{
                 "properties" => %{"id" => %{"type" => "string", "format" => "uuid"}}
               })

      assert :ok = Validator.check_schema(%{"items" => %{"type" => "string", "format" => "date"}})
    end

    test "passes with the wider annotation set the moduledoc lists" do
      for keyword <-
            ~w($id $comment example deprecated readOnly writeOnly x-anything) do
        assert :ok = Validator.check_schema(%{keyword => true})
      end

      assert [m] = problems(%{"X-anything" => true})
      assert m =~ "schema.X-anything is not supported"
    end

    test "passes with atom keys and atom type names" do
      assert :ok =
               Validator.check_schema(%{
                 type: :object,
                 required: [:sku],
                 properties: %{sku: %{type: :string}}
               })
    end

    test "passes for the empty schema and for boolean sub-schemas" do
      assert :ok = Validator.check_schema(%{})
      assert :ok = Validator.check_schema(%{"items" => false, "additionalProperties" => true})
    end
  end

  describe "keywords validate/2 would ignore" do
    test "are refused, each by its path" do
      for keyword <-
            ~w(exclusiveMinimum exclusiveMaximum const multipleOf uniqueItems oneOf anyOf allOf not $ref patternProperties minProperties maxProperties contains if) do
        schema = %{"properties" => %{"price" => %{"type" => "number", keyword => 0}}}

        assert [message] = problems(schema)
        assert message =~ "schema.properties.price.#{keyword} is not supported"
      end
    end

    test "are refused at the root, in items and in additionalProperties" do
      assert [m1] = problems(%{"const" => 1})
      assert m1 =~ "schema.const is not supported"

      assert [m2] = problems(%{"items" => %{"uniqueItems" => true}})
      assert m2 =~ "schema.items.uniqueItems is not supported"

      assert [m3] = problems(%{"additionalProperties" => %{"oneOf" => []}})
      assert m3 =~ "schema.additionalProperties.oneOf is not supported"
    end

    test "all of them are reported, not just the first, and the root label is used" do
      assert {:error, [a, b]} =
               Validator.check_schema(%{"const" => 1, "not" => %{}}, "input_schema")

      assert a =~ "input_schema.const"
      assert b =~ "input_schema.not"
    end
  end

  describe "values validate/2 would ignore or choke on" do
    test "a bound that is not a number or not a non-negative integer" do
      assert [m] = problems(%{"minimum" => "0"})
      assert m =~ "schema.minimum must be a number"

      assert [m] = problems(%{"maximum" => nil})
      assert m =~ "schema.maximum must be a number"

      for keyword <- ~w(minLength maxLength minItems maxItems), value <- [2.0, "2", -1, nil] do
        assert [m] = problems(%{keyword => value})
        assert m =~ "schema.#{keyword} must be a non-negative integer"
      end
    end

    test "an unsupported or empty type" do
      assert [m] = problems(%{"type" => "date"})
      assert m =~ "schema.type must be one of"

      assert [_] = problems(%{"type" => []})
      assert [_] = problems(%{"type" => ["string", "date"]})
      assert [_] = problems(%{"type" => 5})
    end

    test "a pattern that is not a valid regular expression, or not a string" do
      assert [m] = problems(%{"pattern" => "(unclosed"})
      assert m =~ "schema.pattern is not a valid regular expression"

      assert [m] = problems(%{"pattern" => 5})
      assert m =~ "schema.pattern must be a string"
    end

    test "required, enum and properties of the wrong shape" do
      assert [m] = problems(%{"required" => "sku"})
      assert m =~ "schema.required must be a list"

      assert [_] = problems(%{"required" => [1]})

      for member <- [true, false, nil] do
        assert [m] = problems(%{"required" => [member]})
        assert m =~ "schema.required must be a list of property names"
      end

      assert [m] = problems(%{"enum" => "a"})
      assert m =~ "schema.enum must be a list"

      assert [m] = problems(%{"properties" => []})
      assert m =~ "schema.properties must be an object"
    end

    test "a sub-schema that is neither an object nor a boolean" do
      assert [m] = problems(%{"properties" => %{"a" => nil}})
      assert m =~ "schema.properties.a must be an object or a boolean"

      assert [m] = problems(%{"items" => [%{"type" => "string"}]})
      assert m =~ "schema.items must be an object or a boolean"

      assert [_] = problems("object")
    end
  end

  describe "annotation?/1" do
    test "is true for the annotations and lowercase x- keys, false for anything else" do
      for keyword <- ~w(title description default examples example format deprecated readOnly
                        writeOnly $schema $id $comment x-ui x-) do
        assert Validator.annotation?(keyword), keyword
      end

      for keyword <- ~w(type pattern oneOf const $ref xvendor x_vendor X-Vendor) do
        refute Validator.annotation?(keyword), keyword
      end
    end
  end
end
