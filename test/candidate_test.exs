defmodule TailwindSort.CandidateTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Candidate
  alias TailwindSort.Design
  alias TailwindSort.Stylesheet

  setup_all do
    %{d: Design.load_design()}
  end

  describe "parse_candidate/2" do
    test "splits variants, base utility and modifier", %{d: d} do
      assert {[%{kind: :static, root: "hover"}], [{:functional, "bg", {:named, "red-500"}, {:named, "50"}}]} =
               Candidate.parse_candidate("hover:bg-red-500/50", d)
    end

    test "reads an arbitrary property", %{d: d} do
      assert Candidate.parse_candidate("[mask-type:luminance]", d) ==
               {[], [{:arbitrary, "mask-type", "luminance", nil}]}
    end

    test "drops the important marker", %{d: d} do
      assert Candidate.parse_candidate("!p-4", d) == Candidate.parse_candidate("p-4", d)
      assert Candidate.parse_candidate("p-4!", d) == Candidate.parse_candidate("p-4", d)
    end

    test "returns nil when a variant is unknown", %{d: d} do
      assert Candidate.parse_candidate("nope:p-4", d) == nil
    end

    test "returns nil when the base utility is unknown", %{d: d} do
      assert Candidate.parse_candidate("hover:nope-thing", d) == nil
    end

    test "requires the configured prefix" do
      d = Design.build_design(Stylesheet.parse_stylesheet(~s|@import "tailwindcss" prefix(tw);|))

      assert {[], [_ | _]} = Candidate.parse_candidate("tw:p-4", d)
      assert Candidate.parse_candidate("p-4", d) == nil
    end
  end

  describe "find_roots/2" do
    test "tries the longest registered root first" do
      assert Candidate.find_roots("bg-red-500", &(&1 in ["bg", "bg-red"])) ==
               [{"bg-red", "500"}, {"bg", "red-500"}]
    end

    test "returns the whole input with no value when it's a root itself" do
      assert Candidate.find_roots("flex", &(&1 == "flex")) == [{"flex", nil}]
    end

    test "splits a leading `@` as its own root" do
      assert Candidate.find_roots("@container", &(&1 == "@")) == [{"@", "container"}]
    end
  end
end
