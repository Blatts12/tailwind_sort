defmodule TailwindSort.Stylesheet.CssParserTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Stylesheet.CssParser

  describe "parse_css/1" do
    test "builds a tree of blocks, at-rules and declarations" do
      assert CssParser.parse_css(~s|@import "x" prefix(tw); @layer base { a { color: red; } }|) == [
               {:at, ~s|@import "x" prefix(tw)|},
               {:block, "@layer base", [{:block, "a", [{:decl, "color", "red"}]}]}
             ]
    end

    test "drops comments" do
      assert CssParser.parse_css("/* a { color: red; } */ b { color: blue; }") ==
               [{:block, "b", [{:decl, "color", "blue"}]}]
    end

    test "doesn't end a statement at a semicolon inside quotes or parentheses" do
      assert CssParser.parse_css("a { content: 'x;y'; background: url(a;b); }") ==
               [{:block, "a", [{:decl, "content", "'x;y'"}, {:decl, "background", "url(a;b)"}]}]
    end

    test "drops !important from declaration values" do
      assert CssParser.parse_css("a { color: red !important; }") == [{:block, "a", [{:decl, "color", "red"}]}]
    end
  end
end
