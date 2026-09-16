defmodule PhoenixKit.Utils.NumberParseDecimalTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Number

  defp ok(raw, opts \\ []) do
    assert {:ok, %Decimal{} = d} = Number.parse_decimal(raw, opts)
    Decimal.to_string(d, :normal)
  end

  describe "parse_decimal/2 — separators" do
    test "a dot or a comma is the decimal point" do
      assert ok("2.5") == "2.5"
      assert ok("2,5") == "2.5"
      assert ok("0,0005") == "0.0005"
      assert ok(",5") == "0.5"
      assert ok("7") == "7"
    end

    test "surrounding and grouping whitespace is ignored, no-break spaces included" do
      assert ok("  12,5 ") == "12.5"
      assert ok("1 234,56") == "1234.56"
      assert ok("1 234 567.8") == "1234567.8"
    end

    test "spaces group only the integer part, and only between 3-digit groups" do
      assert ok("-1 234,56") == "-1234.56"
      assert ok("1\u00A0234\u202F567") == "1234567"
      assert ok("1  234") == "1234"

      # Two numbers run together, not a grouped one.
      for raw <- ["12 34", "1 2 3", "1,5 25", "1,234 567", "- 5"] do
        assert Number.parse_decimal(raw) == {:error, :invalid}, raw
      end
    end

    test "with both kinds present the last one is the decimal point, the other groups" do
      assert ok("1.234,56") == "1234.56"
      assert ok("1,234.56") == "1234.56"
    end

    test "one kind repeated is thousands grouping" do
      assert ok("1,234,567") == "1234567"
      assert ok("1.234.567") == "1234567"
      assert ok("12.345.678,9") == "12345678.9"
    end

    test "separators that are not grouping are typos, not numbers" do
      for raw <- ["1.2.3,4", "2..5", "1,23,4", ",,5", "1.234.56"] do
        assert Number.parse_decimal(raw) == {:error, :invalid}, raw
      end
    end

    test "a sign is accepted" do
      assert ok("-2,5") == "-2.5"
      assert ok("+3") == "3"
    end

    test "the value is normalized — no trailing zeros, no exponent" do
      assert ok("2.500") == "2.5"
      assert ok("1000") == "1000"
      assert ok("0.0") == "0"
    end

    test "integers keep exponent 0 — structurally equal to Decimal.new of the same text" do
      # Decimal.normalize/1 alone turns "10" into 1E+1, which `==` and
      # to_string/1 (and Jason, and Postgres text casts) treat as a
      # different value from Decimal.new("10").
      assert Number.parse_decimal("10") == {:ok, Decimal.new("10")}
      assert Number.parse_decimal("1 000 000") == {:ok, Decimal.new("1000000")}
      assert Number.parse_decimal(Decimal.new("1E+3")) == {:ok, Decimal.new("1000")}
      assert Number.parse_decimal(Decimal.new("-5E+2")) == {:ok, Decimal.new("-500")}
      assert Number.parse_decimal("10.0") == {:ok, Decimal.new("10")}
      assert Number.parse_decimal("2.50") == {:ok, Decimal.new("2.5")}
      assert {:ok, %Decimal{} = d} = Number.parse_decimal("10")
      assert Decimal.to_string(d) == "10"
      assert Number.format_decimal(Decimal.new("1E+1")) == "10"
    end

    test "a zero is never negative" do
      for raw <- ["-0", "-0,0", -0.0, Decimal.new("-0")] do
        assert {:ok, %Decimal{sign: 1, coef: 0}} = Number.parse_decimal(raw), inspect(raw)
      end

      assert Number.format_decimal(Number.parse_decimal!("-0")) == "0"
    end
  end

  describe "parse_decimal/2 — rejections" do
    test "blank is :empty" do
      assert Number.parse_decimal("") == {:error, :empty}
      assert Number.parse_decimal("   ") == {:error, :empty}
      assert Number.parse_decimal(nil) == {:error, :empty}
    end

    test "garbage, exponent forms and non-finite words are :invalid" do
      for raw <- [
            "abc",
            "1e9",
            "1E-3",
            "NaN",
            "Infinity",
            "-",
            "+",
            ".",
            ",",
            "2..5",
            "12abc",
            "0x1F"
          ] do
        assert Number.parse_decimal(raw) == {:error, :invalid}, raw
      end
    end

    test "tabs and line breaks are not grouping spaces" do
      assert Number.parse_decimal("\t5\n") == {:error, :invalid}
      assert Number.parse_decimal("1\n234") == {:error, :invalid}
    end

    test "an oversized string is rejected before any parsing work" do
      assert Number.parse_decimal(String.duplicate("9", 65)) == {:error, :invalid}
      assert Number.parse_decimal(String.duplicate("1", 5_000_000)) == {:error, :invalid}

      # Inside the bound a long fraction is still legitimate.
      assert {:ok, _} = Number.parse_decimal("0." <> String.duplicate("1", 30))
    end

    test "a non-binary that is not a number is :invalid" do
      assert Number.parse_decimal(:atom) == {:error, :invalid}
      assert Number.parse_decimal(%{}) == {:error, :invalid}
    end
  end

  describe "parse_decimal/2 — already-numeric input" do
    test "integers, floats and decimals pass through as Decimal" do
      assert ok(3) == "3"
      assert ok(2.5) == "2.5"
      assert ok(Decimal.new("1.25")) == "1.25"
    end

    test "non-finite decimals are :invalid" do
      assert Number.parse_decimal(Decimal.new("NaN")) == {:error, :invalid}
      assert Number.parse_decimal(Decimal.new("Infinity")) == {:error, :invalid}
    end
  end

  describe "parse_decimal/2 — bounds" do
    test "min and max reject, they never clamp" do
      assert Number.parse_decimal("-1", min: 0) == {:error, :below_min}
      assert Number.parse_decimal("0", min: 0) == {:ok, Decimal.new("0")}
      assert Number.parse_decimal("101", max: 100) == {:error, :above_max}
      assert ok("99.5", min: 0, max: 100) == "99.5"
    end

    test "bounds accept any numeric shape" do
      assert Number.parse_decimal("0,5", min: Decimal.new("1")) == {:error, :below_min}
      assert Number.parse_decimal("0,5", min: 0.75) == {:error, :below_min}
      assert Number.parse_decimal("0,5", max: "0.25") == {:error, :above_max}
    end

    test "the magnitude ceiling is enforced even without max" do
      assert Number.parse_decimal("9999999999999999") == {:error, :above_max}
      assert ok("999999999999") == "999999999999"
    end
  end

  describe "parse_decimal!/2" do
    test "returns the Decimal or raises ArgumentError" do
      assert Decimal.equal?(Number.parse_decimal!("2,5"), Decimal.new("2.5"))
      assert_raise ArgumentError, ~r/invalid/, fn -> Number.parse_decimal!("abc") end
      assert_raise ArgumentError, ~r/empty/, fn -> Number.parse_decimal!("") end
    end
  end

  describe "format_decimal/1" do
    test "renders a value the way the decimal input shows it" do
      assert Number.format_decimal(Decimal.new("2.500")) == "2.5"
      assert Number.format_decimal(Decimal.new("1E+3")) == "1000"
      assert Number.format_decimal(2) == "2"
      assert Number.format_decimal(2.5) == "2.5"
      assert Number.format_decimal(nil) == ""
      assert Number.format_decimal("2,5") == "2,5"
    end
  end
end
