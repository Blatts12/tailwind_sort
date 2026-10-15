defmodule TailwindSort.DataTypeTest do
  use ExUnit.Case, async: true

  alias TailwindSort.DataType
  alias TailwindSort.Design

  setup_all do
    %{named: Design.load_design().named_colors}
  end

  describe "infer_types/2" do
    test "finds a length", %{named: named} do
      assert "length" in DataType.infer_types("12px", named)
      refute "color" in DataType.infer_types("12px", named)
    end

    test "finds a color", %{named: named} do
      assert "color" in DataType.infer_types("#fff", named)
    end

    test "finds a percentage", %{named: named} do
      assert "percentage" in DataType.infer_types("50%", named)
    end

    test "finds a ratio", %{named: named} do
      assert DataType.infer_types("1/2", named) == MapSet.new(["ratio"])
    end

    test "finds a url", %{named: named} do
      assert "url" in DataType.infer_types("url(a.png)", named)
    end

    test "skips inference for a var() value", %{named: named} do
      assert DataType.infer_types("var(--x)", named) == :var
    end
  end

  describe "color_value?/2" do
    test "accepts named colors in any case", %{named: named} do
      assert DataType.color_value?("Red", named)
    end

    test "accepts color functions", %{named: named} do
      assert DataType.color_value?("rgb(0 0 0)", named)
      assert DataType.color_value?("oklch(0.5 0.1 200)", named)
    end

    test "rejects other words", %{named: named} do
      refute DataType.color_value?("nope", named)
    end
  end
end
