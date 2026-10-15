defmodule TailwindSort.UtilityTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Utility

  setup_all do
    %{d: Design.load_design()}
  end

  describe "compute_signature/2" do
    test "returns nil for a value Tailwind doesn't accept", %{d: d} do
      assert Utility.compute_signature({:functional, "bg", {:named, "nope"}, nil}, d) == nil
    end

    test "accepts only a numeric opacity modifier on an arbitrary property", %{d: d} do
      assert Utility.compute_signature({:arbitrary, "color", "red", {:named, "50"}}, d)
      assert Utility.compute_signature({:arbitrary, "color", "red", {:named, "half"}}, d) == nil
    end

    test "gives a theme value and its arbitrary twin the same signature", %{d: d} do
      assert Utility.compute_signature({:functional, "p", {:named, "4"}, nil}, d) ==
               Utility.compute_signature({:functional, "p", {:arbitrary, nil, "1rem"}, nil}, d)
    end
  end

  describe "compare_signatures/2" do
    test "orders by the CSS properties each utility sets", %{d: d} do
      flex = Utility.compute_signature({:static, "flex"}, d)
      p4 = Utility.compute_signature({:functional, "p", {:named, "4"}, nil}, d)

      assert Utility.compare_signatures(flex, p4) < 0
      assert Utility.compare_signatures(p4, flex) > 0
    end

    test "puts the utility with more declarations first when properties tie" do
      assert Utility.compare_signatures({[1], 2}, {[1], 1}) < 0
    end
  end

  describe "pick_min_signature/1" do
    test "returns the signature that sorts first and skips nils" do
      assert Utility.pick_min_signature([nil, {[5], 1}, {[2], 1}]) == {[2], 1}
    end

    test "returns nil when every signature is nil" do
      assert Utility.pick_min_signature([nil, nil]) == nil
    end
  end
end
