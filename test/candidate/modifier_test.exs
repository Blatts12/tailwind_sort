defmodule TailwindSort.Candidate.ModifierTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Candidate.Modifier

  describe "parse_modifier/1" do
    test "reads a named modifier" do
      assert Modifier.parse_modifier("50") == {:named, "50"}
    end

    test "reads an arbitrary modifier" do
      assert Modifier.parse_modifier("[0.5]") == {:arbitrary, "0.5"}
    end

    test "reads a var shorthand" do
      assert Modifier.parse_modifier("(--x)") == {:var, "var(--x)"}
    end

    test "rejects a shorthand without a variable" do
      assert Modifier.parse_modifier("(x)") == nil
    end

    test "rejects empty and invalid arbitrary modifiers" do
      assert Modifier.parse_modifier("[]") == nil
      assert Modifier.parse_modifier("[a;b]") == nil
    end

    test "rejects characters a named modifier can't hold" do
      assert Modifier.parse_modifier("a/b") == nil
    end
  end
end
