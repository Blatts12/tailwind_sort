defmodule TailwindSort.Variant.OrderTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Variant
  alias TailwindSort.Variant.Order

  setup_all do
    d = Design.load_design()
    %{d: d, compare: &Order.compare_variants(Variant.parse_variant(&1, d), Variant.parse_variant(&2, d), d)}
  end

  describe "compare_variants/3" do
    test "follows Tailwind's variant order", %{compare: compare} do
      assert compare.("hover", "focus") < 0
      assert compare.("md", "lg") < 0
    end

    test "sorts min-* up and max-* down by width", %{compare: compare} do
      assert compare.("min-[400px]", "min-[600px]") < 0
      assert compare.("max-[600px]", "max-[400px]") < 0
    end

    test "puts arbitrary variants after named ones", %{compare: compare} do
      assert compare.("[&_p]", "hover") > 0
    end

    test "treats a variant as equal to itself", %{compare: compare} do
      assert compare.("hover", "hover") == 0
    end
  end
end
