defmodule TailwindSort.DataType.NumberTest do
  use ExUnit.Case, async: true

  alias TailwindSort.DataType.Number

  describe "take_number/1" do
    test "returns the unit after the number" do
      assert Number.take_number("12px") == {:ok, "px"}
    end

    test "reads a sign and a fraction without a leading digit" do
      assert Number.take_number("-.5rem") == {:ok, "rem"}
    end

    test "reads an exponent" do
      assert Number.take_number("1e3") == {:ok, ""}
      assert Number.take_number("+2.5E-3deg") == {:ok, "deg"}
    end

    test "leaves an `e` without digits as part of the unit" do
      assert Number.take_number("1e") == {:ok, "e"}
    end

    test "leaves a trailing dot as part of the unit" do
      assert Number.take_number("1.") == {:ok, "."}
    end

    test "returns :error when the value doesn't start with a number" do
      assert Number.take_number("px") == :error
      assert Number.take_number(".") == :error
    end
  end
end
