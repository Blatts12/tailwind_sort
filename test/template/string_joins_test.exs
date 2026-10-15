defmodule TailwindSort.Template.StringJoinsTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Template.ElixirExpr
  alias TailwindSort.Template.StringJoins

  defp find_edges(src) do
    {:ok, next, strings} = ElixirExpr.scan_expr(src, 1, true)

    src
    |> StringJoins.find_string_edges(1, next - 1, strings)
    |> Enum.map(fn {_lines, lead, trail} -> {lead, trail} end)
  end

  describe "find_string_edges/4" do
    test "leaves strings outside a <> free" do
      assert find_edges(~S|{["p-4", "flex"]}|) == [{:free, :free}, {:free, :free}]
    end

    test "marks an end that meets <> as :space when the string has whitespace there" do
      assert [{:free, :space}, _] = find_edges(~S|{"p-4 " <> @x <> "flex"}|)
    end

    test "marks an end as :glue when nothing separates it from the other side" do
      assert [_, {:glue, :free}] = find_edges(~S|{"p-4 " <> @x <> "flex"}|)
    end

    test "returns no strings when the expression doesn't parse" do
      assert find_edges(~S|{"p-4" <>}|) == []
    end
  end
end
