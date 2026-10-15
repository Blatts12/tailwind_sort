defmodule TailwindSort.Candidate.FunctionalTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Candidate.Functional
  alias TailwindSort.Design

  setup_all do
    %{d: Design.load_design()}
  end

  describe "parse_functional_utility/3" do
    test "returns every root split Tailwind knows, longest root first", %{d: d} do
      assert Functional.parse_functional_utility("inset-x-4", nil, d) == [
               {:functional, "inset-x", {:named, "4"}, nil},
               {:functional, "inset", {:named, "x-4"}, nil}
             ]
    end

    test "reads an arbitrary value", %{d: d} do
      assert Functional.parse_functional_utility("bg-[#fff]", nil, d) ==
               [{:functional, "bg", {:arbitrary, nil, "#fff"}, nil}]
    end

    test "reads a type hint in an arbitrary value", %{d: d} do
      assert Functional.parse_functional_utility("bg-[length:2px]", nil, d) ==
               [{:functional, "bg", {:arbitrary, "length", "2px"}, nil}]
    end

    test "expands the var shorthand", %{d: d} do
      assert Functional.parse_functional_utility("bg-(--brand)", nil, d) ==
               [{:functional, "bg", {:arbitrary, nil, "var(--brand)"}, nil}]
    end

    test "expands the var shorthand with a type", %{d: d} do
      assert Functional.parse_functional_utility("bg-(color:--brand)", nil, d) ==
               [{:functional, "bg", {:arbitrary, "color", "var(--brand)"}, nil}]
    end

    test "passes the modifier through", %{d: d} do
      assert Functional.parse_functional_utility("bg-red-500", {:named, "50"}, d) ==
               [{:functional, "bg", {:named, "red-500"}, {:named, "50"}}]
    end

    test "returns nothing for an unknown root", %{d: d} do
      assert Functional.parse_functional_utility("zz-4", nil, d) == []
    end
  end
end
