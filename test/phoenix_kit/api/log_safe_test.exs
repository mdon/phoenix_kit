defmodule PhoenixKit.API.LogSafeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.LogSafe

  describe "shape/1" do
    test "names the kind and size of a term, never a value" do
      assert LogSafe.shape("secret") == "a binary of 6 bytes"
      assert LogSafe.shape(%{a: "secret"}) == "a map"
      assert LogSafe.shape(%URI{host: "secret"}) == "a URI struct"
      assert LogSafe.shape(["secret"]) == "a list"
      assert LogSafe.shape({"secret", 1}) == "a tuple of size 2"
      assert LogSafe.shape(1.5) == "a value of another type"
    end

    test "names a few plain atoms and no other" do
      for atom <- [nil, true, false, :ok, :error],
          do: assert(LogSafe.shape(atom) == inspect(atom))

      # An atom can be made from a request value (`String.to_atom/1`), so it is
      # not printed, as a term or as the tag of a tuple.
      sentinel =
        String.to_atom("sentinel_" <> Integer.to_string(System.unique_integer([:positive])))

      assert LogSafe.shape(sentinel) == "an atom"
      assert LogSafe.shape({sentinel, 1}) == "a tuple of size 2"
      assert LogSafe.shape({:ok, sentinel}) == "a tuple of size 2 tagged :ok"
      assert LogSafe.shape({:error, "secret"}) == "a tuple of size 2 tagged :error"
    end
  end

  describe "exception_label/1" do
    test "keeps the fixed message of an ArithmeticError and a FunctionClauseError" do
      assert LogSafe.exception_label(%ArithmeticError{}) ==
               "** (ArithmeticError) bad argument in arithmetic expression"

      error = %FunctionClauseError{module: Kernel, function: :hd, arity: 1}

      assert LogSafe.exception_label(error) ==
               "** (FunctionClauseError) no function clause matching in Kernel.hd/1"
    end

    test "builds that text from the exception class, not from the instance" do
      label = LogSafe.exception_label(%ArithmeticError{message: "SENTINEL"})
      assert label == "** (ArithmeticError) bad argument in arithmetic expression"

      # Blamed, a FunctionClauseError prints the arguments it was called with.
      error = %FunctionClauseError{
        module: Kernel,
        function: :hd,
        arity: 1,
        args: ["SENTINEL"],
        clauses: [{[{:list, [], nil}], []}]
      }

      label = LogSafe.exception_label(error)
      assert label == "** (FunctionClauseError) no function clause matching in Kernel.hd/1"
      refute label =~ "SENTINEL"
    end

    test "cuts the text at 500 code points" do
      # An atom is at most 255 characters, so the text needs both names to pass 500.
      module = String.to_atom(String.duplicate("m", 250))
      function = String.to_atom(String.duplicate("f", 250))
      error = %FunctionClauseError{module: module, function: function, arity: 1}

      label = LogSafe.exception_label(error)
      assert String.starts_with?(label, "** (FunctionClauseError) no function clause matching")
      assert String.length(label) == String.length("** (FunctionClauseError) ") + 500
    end

    test "drops the message of RuntimeError, ArgumentError and UndefinedFunctionError" do
      assert LogSafe.exception_label(%RuntimeError{message: "SENTINEL"}) == "** (RuntimeError)"
      assert LogSafe.exception_label(%ArgumentError{message: "SENTINEL"}) == "** (ArgumentError)"

      error = %UndefinedFunctionError{module: SENTINEL, function: :nope, arity: 0}
      assert LogSafe.exception_label(error) == "** (UndefinedFunctionError)"
    end

    test "drops the message of any other exception" do
      error = %KeyError{key: "secret", term: %{"cart_token" => "secret"}}
      assert LogSafe.exception_label(error) == "** (KeyError)"
    end
  end
end
