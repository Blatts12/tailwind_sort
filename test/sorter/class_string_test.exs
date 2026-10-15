defmodule TailwindSort.Sorter.ClassStringTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Sorter.ClassString

  setup_all do
    %{d: Design.load_design()}
  end

  describe "sort_class_string/3" do
    test "collapses whitespace and trims the ends", %{d: d} do
      assert ClassString.sort_class_string("  p-4\n flex ", d) == "flex p-4"
    end

    test "keeps one space at each end with collapse_start and collapse_end off", %{d: d} do
      assert ClassString.sort_class_string("  p-4 flex ", d, collapse_start: false, collapse_end: false) ==
               " flex p-4 "
    end

    test "keeps the first class in place with ignore_first", %{d: d} do
      assert ClassString.sort_class_string("-x p-4 flex", d, ignore_first: true) == "-x flex p-4"
    end

    test "keeps the last class in place with ignore_last", %{d: d} do
      assert ClassString.sort_class_string("p-4 flex mt-", d) == "mt- flex p-4"
      assert ClassString.sort_class_string("p-4 flex mt-", d, ignore_last: true) == "flex p-4 mt-"
    end

    test "turns a blank string into an empty one", %{d: d} do
      assert ClassString.sort_class_string("   ", d) == ""
    end
  end
end
