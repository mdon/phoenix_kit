defmodule PhoenixKit.API.ValidatorScalarsTest do
  @moduledoc """
  `PhoenixKit.API.Validator`: the keywords of numbers (`minimum`, `maximum`)
  and strings (`minLength`, `maxLength`, `pattern`).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator

  defp errors(schema, input) do
    assert {:error, errors} = Validator.validate(schema, input)
    errors
  end

  # Runs `fun` in a process that is killed when its heap passes `words`.
  defp run_with_heap_limit(words, fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
        send(parent, {:result, fun.()})
      end)

    receive do
      {:result, result} ->
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("the validating process died: #{inspect(reason)}")
    end
  end

  describe "minimum and maximum" do
    @range %{"type" => "number", "minimum" => 0, "maximum" => 100}

    test "are inclusive" do
      assert {:ok, 0} = Validator.validate(@range, 0)
      assert {:ok, 100} = Validator.validate(@range, 100)
      assert {:ok, 99.99} = Validator.validate(@range, 99.99)
    end

    test "report the bound that was broken" do
      assert [%{message: "must be at least 0", limit: 0, allowed: nil}] = errors(@range, -1)
      assert [%{message: "must be at most 100", limit: 100}] = errors(@range, 100.5)
    end

    test "apply to integers too, at a path" do
      schema = %{
        "type" => "object",
        "properties" => %{"quantity" => %{"type" => "integer", "minimum" => 1}}
      }

      assert [%{path: "quantity", limit: 1}] = errors(schema, %{"quantity" => 0})
    end
  end

  describe "minLength and maxLength" do
    @name %{"type" => "string", "minLength" => 2, "maxLength" => 5}

    test "are inclusive and count characters, not bytes" do
      assert {:ok, "ab"} = Validator.validate(@name, "ab")
      assert {:ok, "abcde"} = Validator.validate(@name, "abcde")
      # 5 characters, 6 bytes
      assert {:ok, "señor"} = Validator.validate(@name, "señor")
      # 2 characters, 4 bytes
      assert {:ok, "éñ"} = Validator.validate(@name, "éñ")
    end

    test "count code points, not graphemes: a combining mark is a character" do
      # "e" + U+0301 is one grapheme, two code points
      decomposed = "e\u0301"
      assert String.length(decomposed) == 1

      assert {:ok, ^decomposed} = Validator.validate(%{"minLength" => 2}, decomposed)
      assert [%{limit: 1}] = errors(%{"maxLength" => 1}, decomposed)
      # an emoji is one code point
      assert {:ok, _} = Validator.validate(%{"maxLength" => 1}, "\u{1F600}")
      assert [%{limit: 1}] = errors(%{"maxLength" => 1}, "\u{1F600}\u{1F600}")
    end

    test "decide correctly where the byte length cannot (2 to 4 bytes per character)" do
      for {char, bytes} <- [{"a", 1}, {"\u00e9", 2}, {"\u20ac", 3}, {"\u{1F600}", 4}] do
        assert byte_size(char) == bytes
        schema = %{"minLength" => 3, "maxLength" => 3}

        assert {:ok, _} = Validator.validate(schema, String.duplicate(char, 3))

        assert [%{limit: 3, message: "must be at least 3 characters"}] =
                 errors(schema, String.duplicate(char, 2))

        assert [%{limit: 3, message: "must be at most 3 characters"}] =
                 errors(schema, String.duplicate(char, 4))
      end
    end

    test "a byte that is not UTF-8 counts as one character" do
      assert {:ok, _} =
               Validator.validate(%{"minLength" => 3, "maxLength" => 3}, <<255, 255, 255>>)

      assert [%{limit: 2}] = errors(%{"maxLength" => 2}, <<255, 255, 255>>)
    end

    test "a 2 MB string costs no memory proportional to its length" do
      big = String.duplicate("\u00e9", 1_000_000)
      assert byte_size(big) == 2_000_000

      # 100_000 words = 800 kB of heap; a list of 1 000 000 characters needs 2 000 000 words
      result =
        run_with_heap_limit(100_000, fn ->
          [
            Validator.validate(%{"type" => "string"}, big),
            Validator.validate(%{"type" => "string", "maxLength" => 1_500_000}, big),
            Validator.validate(
              %{"type" => "string", "minLength" => 999_999, "maxLength" => 1_000_000},
              big
            ),
            Validator.validate(%{"type" => "string", "maxLength" => 10}, big)
          ]
        end)

      assert [{:ok, ^big}, {:ok, ^big}, {:ok, ^big}, {:error, [%{limit: 10}]}] = result
    end

    test "report the bound that was broken" do
      assert [%{message: "must be at least 2 characters", limit: 2}] = errors(@name, "a")
      assert [%{message: "must be at most 5 characters", limit: 5}] = errors(@name, "abcdef")

      assert [%{message: "must be at least 1 character", limit: 1}] =
               errors(%{"minLength" => 1}, "")
    end
  end

  describe "pattern" do
    test "matches unanchored, as JSON Schema does" do
      schema = %{"type" => "string", "pattern" => "^[A-Z]{3}-\\d+$"}

      assert {:ok, "ABC-12"} = Validator.validate(schema, "ABC-12")

      assert [%{message: "must match the pattern ^[A-Z]{3}-\\d+$", limit: "^[A-Z]{3}-\\d+$"}] =
               errors(schema, "abc-12")

      assert {:ok, "xx cat xx"} = Validator.validate(%{"pattern" => "cat"}, "xx cat xx")
    end

    test "an invalid pattern is a bug in the schema, even when no string reaches it" do
      assert_raise ArgumentError, ~r/invalid pattern/, fn ->
        Validator.validate(%{"type" => "string", "pattern" => "(unclosed"}, "x")
      end

      schema = %{"properties" => %{"sku" => %{"pattern" => "(unclosed"}}}

      assert_raise ArgumentError, ~r/invalid pattern/, fn ->
        Validator.validate(schema, %{})
      end
    end

    test "$ does not match before a trailing newline (JSON Schema, not PCRE)" do
      schema = %{"type" => "string", "pattern" => "^[A-Z0-9-]+$"}

      assert {:ok, "ABC-1"} = Validator.validate(schema, "ABC-1")
      assert [%{limit: "^[A-Z0-9-]+$"}] = errors(schema, "ABC-1\n")
      assert [_] = errors(%{"pattern" => "^\\d+$"}, "12\n")
    end

    test "\\d and \\w are ASCII only, as in JSON Schema" do
      # Arabic-Indic digits and an accented letter
      assert [_] = errors(%{"pattern" => "^\\d+$"}, "\u0661\u0662\u0663")
      assert [_] = errors(%{"pattern" => "^\\w+$"}, "caf\u00e9")
      assert [_] = errors(%{"pattern" => "^[[:alpha:]]+$"}, "caf\u00e9")
      assert {:ok, _} = Validator.validate(%{"pattern" => "^\\d+$"}, "123")
    end

    test "a string that is not valid UTF-8 does not match a pattern and does not raise" do
      assert [%{limit: "^a"}] = errors(%{"type" => "string", "pattern" => "^a"}, <<255>>)
      assert [%{limit: "^a"}] = errors(%{"pattern" => "^a"}, <<?a, 255>>)
      assert {:ok, "ab"} = Validator.validate(%{"pattern" => "^a"}, "ab")
    end

    test "a pattern matches code points, not bytes" do
      one = %{"pattern" => "^.$"}

      assert {:ok, _} = Validator.validate(one, "\u00e9")
      assert {:ok, _} = Validator.validate(one, "\u{1F600}")
      assert [_] = errors(one, "ab")
      assert {:ok, _} = Validator.validate(%{"pattern" => "^\u00e9$"}, "\u00e9")
    end

    test "a pattern of a property or of every element is applied" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "sku" => %{"type" => "string", "pattern" => "^A"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string", "pattern" => "^t"}}
        },
        "additionalProperties" => %{"type" => "string", "pattern" => "^x"}
      }

      assert {:ok, _} =
               Validator.validate(schema, %{"sku" => "A1", "tags" => ["t1"], "other" => "x"})

      assert Enum.map(
               errors(schema, %{"sku" => "B", "tags" => ["t1", "u"], "other" => "y"}),
               & &1.path
             ) == ["other", "sku", "tags[1]"]
    end
  end
end
