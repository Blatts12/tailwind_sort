defmodule TailwindSort.Template.ElixirExprTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Template.ElixirExpr

  describe "scan_expr/3" do
    test "finds the matching brace past braces in strings, char literals, sigils and comments" do
      src = ~S|{"}" <> ?} <> ~s(}) <> f(%{a: 1}) # }| <> "\n} rest"
      assert {:ok, next, _} = ElixirExpr.scan_expr(src, 1, false)
      assert binary_part(src, next, byte_size(src) - next) == " rest"
    end

    test "collects double-quoted strings as chunks around interpolation" do
      src = ~S|{"p-4 #{@x} flex"}|

      assert ElixirExpr.scan_expr(src, 1, true) ==
               {:ok, byte_size(src), [{1, [[{:static, 2, 6}, {:dynamic, 6, 11}, {:static, 11, 16}]]}]}
    end

    test "skips charlists" do
      assert {:ok, _, []} = ElixirExpr.scan_expr(~S|{'p-4 flex'}|, 1, true)
    end

    test "collects nothing without collect?" do
      assert {:ok, _, []} = ElixirExpr.scan_expr(~S|{"p-4 flex"}|, 1, false)
    end

    test "returns :error when the expression never closes" do
      assert ElixirExpr.scan_expr(~S|{"p-4 flex"|, 1, true) == :error
    end
  end
end
