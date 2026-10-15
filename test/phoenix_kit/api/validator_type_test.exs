defmodule PhoenixKit.API.ValidatorTypeTest do
  @moduledoc """
  `PhoenixKit.API.Validator`: `type`, `enum` and the shape of an error for the
  input as a whole.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator

  defp errors(schema, input) do
    assert {:error, errors} = Validator.validate(schema, input)
    errors
  end

  describe "type" do
    test "accepts a value of the declared type and refuses another" do
      cases = [
        {"string", "a", 1, "must be a string"},
        {"integer", 3, "3", "must be an integer"},
        {"integer", 3, 3.5, "must be an integer"},
        {"number", 3.5, "3.5", "must be a number"},
        {"number", 3, true, "must be a number"},
        {"boolean", false, "false", "must be a boolean"},
        {"object", %{}, [], "must be an object"},
        {"array", [], %{}, "must be an array"},
        {"null", nil, 0, "must be null"}
      ]

      for {type, good, bad, message} <- cases do
        schema = %{"type" => type}

        assert {:ok, ^good} = Validator.validate(schema, good),
               "#{type} should accept #{inspect(good)}"

        assert [%{path: "", message: ^message, limit: nil, allowed: nil}] = errors(schema, bad)
      end
    end

    test "a boolean is not an integer or a number, and nil is not an object" do
      assert [_] = errors(%{"type" => "integer"}, true)
      assert [_] = errors(%{"type" => "number"}, false)
      assert [_] = errors(%{"type" => "object"}, nil)
    end

    test "a list of types accepts any of them" do
      schema = %{"type" => ["string", "null"]}

      assert {:ok, "x"} = Validator.validate(schema, "x")
      assert {:ok, nil} = Validator.validate(schema, nil)
      assert [%{message: "must be of type string or null"}] = errors(schema, 5)
    end

    test "a float with no fractional part is an integer, and comes back as one" do
      assert {:ok, 3} = Validator.validate(%{"type" => "integer"}, 3.0)
      assert {:ok, 3} = Validator.validate(%{"type" => ["integer", "null"]}, 3.0)
      assert [%{path: "", message: "must be an integer"}] = errors(%{"type" => "integer"}, 3.5)
    end

    test "no type means any value" do
      for value <- [1, "a", nil, [1], %{"a" => 1}, true] do
        assert {:ok, ^value} = Validator.validate(%{}, value)
      end
    end

    test "an unsupported type is a bug in the schema" do
      assert_raise ArgumentError, ~r/unsupported JSON Schema type "date"/, fn ->
        Validator.validate(%{"type" => "date"}, "2026-01-01")
      end
    end
  end

  describe "enum" do
    test "accepts a listed value and reports the allowed ones" do
      schema = %{"type" => "string", "enum" => ["draft", "active", "archived"]}

      assert {:ok, "active"} = Validator.validate(schema, "active")

      assert [
               %{
                 path: "",
                 message: "must be one of: draft, active, archived",
                 limit: nil,
                 allowed: ["draft", "active", "archived"]
               }
             ] = errors(schema, "deleted")
    end

    test "numbers are compared as JSON compares them: 1 and 1.0 are the same member" do
      assert {:ok, 2.0} = Validator.validate(%{"enum" => [1, 2, 3]}, 2.0)
      assert {:ok, 1} = Validator.validate(%{"type" => "number", "enum" => [1.0]}, 1)
      assert [_] = errors(%{"enum" => [1, 2, 3]}, 2.5)
      assert [_] = errors(%{"enum" => [1, 2, 3]}, "2")
    end

    test "null is shown as null, not nil" do
      assert [%{message: "must be one of: null, 1", allowed: [nil, 1]}] =
               errors(%{"enum" => [nil, 1]}, 2)
    end

    test "an enum error comes before the errors of the value's own kind" do
      schema = %{"type" => "string", "enum" => ["abc"], "minLength" => 3}

      assert [%{message: "must be one of: abc"}, %{message: "must be at least 3 characters"}] =
               errors(schema, "b")
    end

    test "atom members are compared as strings" do
      schema = %{"enum" => [:asc, :desc]}

      assert {:ok, "asc"} = Validator.validate(schema, "asc")
      assert [%{allowed: ["asc", "desc"]}] = errors(schema, "up")
    end
  end

  describe "boolean sub-schemas" do
    test "true accepts anything and false accepts nothing" do
      assert {:ok, 5} = Validator.validate(%{"properties" => %{"a" => true}}, 5)

      assert {:ok, %{"a" => [1]}} =
               Validator.validate(%{"properties" => %{"a" => true}}, %{"a" => [1]})

      assert [%{path: "a", message: "is not allowed"}] =
               errors(%{"properties" => %{"a" => false}}, %{"a" => 1})

      assert {:ok, %{"x" => 1}} =
               Validator.validate(%{"additionalProperties" => true}, %{"x" => 1})

      assert [%{path: "[0]", message: "is not allowed"}] =
               errors(%{"items" => false}, [1])

      assert {:ok, [1]} = Validator.validate(%{"items" => true}, [1])
      assert {:ok, []} = Validator.validate(%{"items" => false}, [])
    end
  end

  describe "validate/2 on the whole input" do
    test "a type mismatch of the input itself has the empty path" do
      assert [%{path: "", message: "must be an object"}] = errors(%{"type" => "object"}, "nope")
    end

    test "a type mismatch stops further checks on that value" do
      # minimum and enum both apply to the value 5 itself: they must not add errors
      schema = %{"type" => "string", "minimum" => 10, "enum" => ["a"]}
      assert [%{path: "", message: "must be a string"}] = errors(schema, 5)
    end
  end
end
