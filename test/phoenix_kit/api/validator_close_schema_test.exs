defmodule PhoenixKit.API.ValidatorCloseSchemaTest do
  @moduledoc """
  `PhoenixKit.API.Validator.close_schema/2`: executor control fields are added to
  a tool's schema and everything else stays refused.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator

  defp errors(schema, input) do
    assert {:error, errors} = Validator.validate(schema, input)
    errors
  end

  describe "close_schema/2" do
    @control %{
      "dry_run" => %{"type" => "boolean"},
      "idempotency_key" => %{"type" => "string", "minLength" => 8, "maxLength" => 64}
    }

    test "lets the control fields through and still refuses everything else" do
      schema = %{
        "type" => "object",
        "required" => ["sku"],
        "properties" => %{"sku" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      closed = Validator.close_schema(schema, @control)

      assert {:ok, _} = Validator.validate(closed, %{"sku" => "A", "dry_run" => true})

      assert [%{path: "dry_run", message: "must be a boolean"}] =
               errors(closed, %{"sku" => "A", "dry_run" => "yes"})

      assert [%{path: "idempotency_key", limit: 8}] =
               errors(closed, %{"sku" => "A", "idempotency_key" => "short"})

      assert [%{path: "color", message: "is not allowed"}] =
               errors(closed, %{"sku" => "A", "color" => "red"})
    end

    test "a schema that did not close itself is closed" do
      closed =
        Validator.close_schema(
          %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
          @control
        )

      assert closed["additionalProperties"] == false
      assert [%{path: "zzz"}] = errors(closed, %{"zzz" => 1})
    end

    test "a control field replaces a property of the same name that a module declared" do
      schema = %{"type" => "object", "properties" => %{"dry_run" => %{"type" => "string"}}}
      closed = Validator.close_schema(schema, @control)

      assert {:ok, _} = Validator.validate(closed, %{"dry_run" => false})
    end

    test "an open schema is closed too: an explicit additionalProperties is overridden" do
      for open <- [true, %{"type" => "string"}] do
        schema = %{
          "type" => "object",
          "properties" => %{"a" => %{"type" => "string"}},
          "additionalProperties" => open
        }

        closed = Validator.close_schema(schema, @control)

        assert closed["additionalProperties"] == false
        assert {:ok, _} = Validator.validate(closed, %{"a" => "x", "dry_run" => true})

        for field <- ["confirm_token", "currency", "language"] do
          assert [%{path: ^field, message: "is not allowed"}] =
                   errors(closed, %{"a" => "x", field => "v"})
        end
      end
    end

    test "properties that are not an object are replaced by the control fields" do
      closed = Validator.close_schema(%{"type" => "object", "properties" => nil}, @control)

      assert closed["properties"] == @control
      assert {:ok, _} = Validator.validate(closed, %{"dry_run" => false})
    end

    test "a schema without properties gets only the control fields" do
      closed = Validator.close_schema(%{"type" => "object"}, @control)

      assert closed["properties"] == @control
      assert {:ok, _} = Validator.validate(closed, %{})
    end

    test "returns string keys even for an atom-keyed schema, and leaves the argument alone" do
      schema = %{type: "object", properties: %{sku: %{type: "string"}}}
      closed = Validator.close_schema(schema, %{dry_run: %{type: "boolean"}})

      assert Map.keys(closed) |> Enum.sort() == ["additionalProperties", "properties", "type"]
      assert Map.keys(closed["properties"]) |> Enum.sort() == ["dry_run", "sku"]
      assert schema == %{type: "object", properties: %{sku: %{type: "string"}}}
    end
  end
end
