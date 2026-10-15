defmodule TailwindSort.Design.VariantTableTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Design.VariantTable

  setup_all do
    %{data: Design.load_tailwind_data()}
  end

  describe "build_variant_table/3" do
    test "gives each theme breakpoint the breakpoint order", %{data: data} do
      {variants, _} = VariantTable.build_variant_table(data, %{"--breakpoint-3xl" => "120rem"}, [])
      assert variants["3xl"].order == data.breakpoint_order
    end

    test "puts a new custom variant after every other variant", %{data: data} do
      {variants, _} = VariantTable.build_variant_table(data, %{}, [{"pointer", ["@media (pointer: fine)"]}])
      others = variants |> Map.delete("pointer") |> Map.values() |> Enum.map(& &1.order)

      assert variants["pointer"].order > Enum.max(others)
    end

    test "keeps the order of a core variant that a custom one replaces", %{data: data} do
      {core, _} = VariantTable.build_variant_table(data, %{}, [])
      {variants, _} = VariantTable.build_variant_table(data, %{}, [{"hover", ["@media (hover: hover)"]}])

      assert variants["hover"].order == core["hover"].order
      assert variants["hover"].compounds == 1
    end

    test "maps min and max to breakpoint comparators", %{data: data} do
      {variants, comparators} = VariantTable.build_variant_table(data, %{}, [])

      assert comparators[variants["min"].order] == {:breakpoint, :asc}
      assert comparators[variants["max"].order] == {:breakpoint, :desc}
      assert comparators[variants["@min"].order] == {:container, :asc}
    end
  end

  describe "compute_selector_compounds/1" do
    test "sets bit 1 for at-rules and bit 2 for style rules" do
      assert VariantTable.compute_selector_compounds(["@media print"]) == 1
      assert VariantTable.compute_selector_compounds(["&:hover"]) == 2
      assert VariantTable.compute_selector_compounds(["@media print", "&:hover"]) == 3
    end

    test "returns 0 for pseudo-elements and other at-rules" do
      assert VariantTable.compute_selector_compounds(["&::before"]) == 0
      assert VariantTable.compute_selector_compounds(["@font-face"]) == 0
    end
  end
end
