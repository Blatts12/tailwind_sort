defmodule TailwindSort.Template.StringJoins do
  @moduledoc """
  Tells which strings in a `class={...}` expression sit inside a `<>`.

  Where two strings join, the whitespace between them matters, and a class touching `<>` with no
  space may glue onto the other side. The scanner already found the strings as byte offsets.
  Here we parse the expression and match each string to its place in the AST.
  """

  alias TailwindSort.Template.ElixirExpr
  alias TailwindSort.Text

  @typedoc """
  What touches one end of a string: `:free` for nothing, `:space` for `<>` with whitespace on the
  other side, `:glue` for `<>` with anything else.
  """
  @type edge :: :free | :space | :glue

  @doc """
  Pairs each string from `TailwindSort.Template.ElixirExpr.scan_expr/3` with the edges that
  touch it. `src[start..stop)` is the expression. When it doesn't parse, we return no strings,
  so nothing gets sorted.
  """
  @spec find_string_edges(String.t(), non_neg_integer(), non_neg_integer(), [ElixirExpr.found_string()]) ::
          [{lines :: [[ElixirExpr.chunk()]], lead :: edge(), trail :: edge()}]
  def find_string_edges(src, start, stop, strings) do
    expr = binary_part(src, start, stop - start)
    encode = &{:ok, {:__block__, &2, [&1]}}

    case Code.string_to_quoted(expr, columns: true, emit_warnings: false, literal_encoder: encode) do
      {:ok, ast} ->
        joins = collect_joined_edges(ast, :free, :free, %{})

        Enum.map(strings, fn {open, lines} ->
          {lead, trail} = Map.get(joins, find_line_column(src, start, open), {:free, :free})
          {lines, lead, trail}
        end)

      {:error, _} ->
        []
    end
  end

  # The AST counts columns in codepoints, so UTF-8 continuation bytes don't count.
  defp find_line_column(src, start, pos) do
    before = src |> binary_part(start, pos - start) |> :binary.split("\n", [:global])
    column = before |> List.last() |> :binary.bin_to_list() |> Enum.count(&(&1 not in 0x80..0xBF))
    {length(before), column + 1}
  end

  # Maps `{line, column}` of each string inside a `<>` to its `{lead, trail}`. Like
  # canCollapseWhitespaceIn in prettier-plugin-tailwindcss, a string anywhere inside an operand
  # counts, so `@a <> if(@b, do: " p-4")` keeps its space.
  defp collect_joined_edges({:<>, _, [left, right]}, lead, trail, acc) do
    acc = collect_joined_edges(left, lead, read_string_edge(right, :first), acc)
    collect_joined_edges(right, read_string_edge(left, :last), trail, acc)
  end

  defp collect_joined_edges({form, meta, args} = string, lead, trail, acc)
       when (form == :__block__ and is_list(args) and length(args) == 1 and is_binary(hd(args))) or form == :<<>> do
    # A string can't glue on a side where it starts or ends in whitespace itself.
    lead = if lead == :glue, do: read_string_edge(string, :first), else: lead
    trail = if trail == :glue, do: read_string_edge(string, :last), else: trail
    acc = if {lead, trail} == {:free, :free}, do: acc, else: Map.put(acc, {meta[:line], meta[:column]}, {lead, trail})
    collect_joined_edges(args, lead, trail, acc)
  end

  defp collect_joined_edges({form, _, args}, lead, trail, acc) when is_list(args),
    do: collect_joined_edges([form | args], lead, trail, acc)

  defp collect_joined_edges({a, b}, lead, trail, acc), do: collect_joined_edges([a, b], lead, trail, acc)

  defp collect_joined_edges(nodes, lead, trail, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect_joined_edges(&1, lead, trail, &2))

  defp collect_joined_edges(_, _, _, acc), do: acc

  # Whether the first or last character of an expression's value is whitespace, as far as we
  # can tell without running it.
  defp read_string_edge({:__block__, _, [s]}, :first) when is_binary(s),
    do: if(Text.trim_leading_whitespace(s) == s, do: :glue, else: :space)

  defp read_string_edge({:__block__, _, [s]}, :last) when is_binary(s),
    do: if(Text.trim_trailing_whitespace(s) == s, do: :glue, else: :space)

  defp read_string_edge({:<<>>, _, [part | _]}, :first), do: read_string_edge({:__block__, [], [part]}, :first)
  defp read_string_edge({:<<>>, _, parts}, :last), do: read_string_edge({:__block__, [], [List.last(parts)]}, :last)
  defp read_string_edge({:<>, _, [left, _]}, :first), do: read_string_edge(left, :first)
  defp read_string_edge({:<>, _, [_, right]}, :last), do: read_string_edge(right, :last)
  defp read_string_edge(_, _), do: :glue
end
