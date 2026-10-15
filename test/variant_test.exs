defmodule TailwindSort.VariantTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Variant

  setup_all do
    %{d: Design.load_design()}
  end

  describe "parse_variant/2" do
    test "reads a static variant", %{d: d} do
      assert %{kind: :static, root: "hover"} = Variant.parse_variant("hover", d)
    end

    test "reads a functional variant with an arbitrary value", %{d: d} do
      assert %{kind: :functional, root: "min", value: {:arbitrary, "600px", :arb}} =
               Variant.parse_variant("min-[600px]", d)
    end

    test "reads a compound variant and its modifier", %{d: d} do
      assert %{kind: :compound, root: "group", modifier: {:named, "name"}, variant: %{root: "hover"}} =
               Variant.parse_variant("group-hover/name", d)
    end

    test "wraps a plain arbitrary selector in &:is()", %{d: d} do
      assert %{kind: :arbitrary, selector: "&:is(.dark)"} = Variant.parse_variant("[.dark]", d)
      assert %{kind: :arbitrary, selector: ".dark &"} = Variant.parse_variant("[.dark_&]", d)
    end

    test "returns nil for an unknown variant", %{d: d} do
      assert Variant.parse_variant("nope", d) == nil
    end

    test "returns nil for a modifier on a static variant", %{d: d} do
      assert Variant.parse_variant("hover/50", d) == nil
    end
  end

  describe "compounds_with?/3" do
    test "lets group-* wrap a style rule variant", %{d: d} do
      assert Variant.compounds_with?("group", Variant.parse_variant("hover", d), d)
    end

    test "doesn't let group-* wrap a pseudo-element", %{d: d} do
      refute Variant.compounds_with?("group", Variant.parse_variant("before", d), d)
    end
  end

  describe "produces_css?/2" do
    test "accepts a plain variant", %{d: d} do
      assert Variant.produces_css?(Variant.parse_variant("hover", d), d)
    end

    test "rejects a relative selector at the top level but not inside has-*", %{d: d} do
      refute Variant.produces_css?(Variant.parse_variant("[>p]", d), d)
      assert Variant.produces_css?(Variant.parse_variant("has-[>p]", d), d)
    end

    test "rejects compound chains Tailwind refuses to compile", %{d: d} do
      refute Variant.produces_css?(Variant.parse_variant("group-not-hover", d), d)
    end
  end
end
