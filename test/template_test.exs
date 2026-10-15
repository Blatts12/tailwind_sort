defmodule TailwindSort.TemplateTest do
  # Most template behavior goes through TailwindSort.format/2 in tailwind_sort_test.exs.
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Template

  setup_all do
    %{d: Design.load_design()}
  end

  describe "sort_class_attributes/3" do
    test "drops known duplicates by default", %{d: d} do
      assert Template.sort_class_attributes(~s(<div class="p-4 flex p-4"></div>), d, []) ==
               ~s(<div class="flex p-4"></div>)
    end

    test "keeps duplicates with remove_duplicates: false", %{d: d} do
      assert Template.sort_class_attributes(~s(<div class="p-4 flex p-4"></div>), d, remove_duplicates: false) ==
               ~s(<div class="flex p-4 p-4"></div>)
    end

    test "returns the template as is when nothing needs sorting", %{d: d} do
      src = ~s(<div class="flex p-4"><span>p-4 flex</span></div>)
      assert Template.sort_class_attributes(src, d, []) == src
    end
  end
end
