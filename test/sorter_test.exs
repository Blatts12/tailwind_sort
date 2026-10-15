defmodule TailwindSort.SorterTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Sorter

  setup_all do
    %{d: Design.load_design()}
  end

  describe "build_class_order/2" do
    test "gives nil to a class Tailwind doesn't generate", %{d: d} do
      order = Sorter.build_class_order(["p-4", "nope"], d)

      assert order["nope"] == nil
      assert {_, _, "p-4"} = order["p-4"]
    end

    test "gives nil to a class whose variant produces no CSS", %{d: d} do
      assert Sorter.build_class_order(["[>p]:flex"], d) == %{"[>p]:flex" => nil}
    end
  end

  describe "compare_sort_keys/2" do
    test "puts a utility without variants before one with variants", %{d: d} do
      order = Sorter.build_class_order(["p-4", "hover:flex"], d)
      assert Sorter.compare_sort_keys(order["p-4"], order["hover:flex"]) < 0
    end

    test "orders utilities by the CSS properties they set", %{d: d} do
      order = Sorter.build_class_order(["p-4", "flex"], d)
      assert Sorter.compare_sort_keys(order["flex"], order["p-4"]) < 0
    end
  end

  describe "sort_class_list/3" do
    test "puts unknown classes first and `...` last", %{d: d} do
      assert {["nope", "flex", "p-4", "..."], _} = Sorter.sort_class_list(["p-4", "...", "flex", "nope"], d)
    end

    test "drops known duplicates and counts them", %{d: d} do
      assert Sorter.sort_class_list(["p-4", "flex", "p-4"], d) == {["flex", "p-4"], 1}
    end

    test "keeps duplicates with remove_duplicates: false", %{d: d} do
      assert Sorter.sort_class_list(["p-4", "flex", "p-4"], d, remove_duplicates: false) ==
               {["flex", "p-4", "p-4"], 0}
    end
  end
end
