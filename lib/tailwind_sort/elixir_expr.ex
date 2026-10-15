defmodule TailwindSort.ElixirExpr do
  @moduledoc ~S"""
  Scans the Elixir expression inside a template's `{...}`, like the one in `class={...}`.

  `scan_expr/3` finds where the expression ends and where its double-quoted strings sit, as byte
  offsets. A string comes back as lines of chunks. `#{}` splits a line into `:static` and
  `:dynamic` chunks, and a heredoc has one line per source line.

  `find_string_edges/4` tells which of those strings sit inside a `<>`, so the sorter keeps the
  whitespace where they join.
  """

  import TailwindSort.ByteScan

  alias TailwindSort.Text

  @type chunk :: {:static | :dynamic, non_neg_integer(), non_neg_integer()}
  @type found_string :: {open_quote :: non_neg_integer(), lines :: [[chunk()]]}

  @typedoc """
  What touches one end of a string: `:free` for nothing, `:space` for `<>` with whitespace on the
  other side, `:glue` for `<>` with anything else.
  """
  @type edge :: :free | :space | :glue

  @doc """
  Scans from just after an opening `{` to the matching `}`. Returns the offset after the `}`.
  With `collect?` set, it also returns the double-quoted strings it passed.
  """
  @spec scan_expr(String.t(), non_neg_integer(), boolean()) :: {:ok, non_neg_integer(), [found_string()]} | :error
  def scan_expr(src, pos, collect?), do: scan_expr(src, pos, 1, collect?, [])

  defp scan_expr(src, pos, _depth, _collect, _strings) when pos >= byte_size(src), do: :error

  defp scan_expr(src, pos, depth, collect, strings) do
    case binary_part(src, pos, min(3, byte_size(src) - pos)) do
      "}" <> _ when depth == 1 ->
        {:ok, pos + 1, Enum.reverse(strings)}

      "}" <> _ ->
        scan_expr(src, pos + 1, depth - 1, collect, strings)

      "{" <> _ ->
        scan_expr(src, pos + 1, depth + 1, collect, strings)

      ~s(""") ->
        scan_string_literal(src, pos, ~s("""), depth, collect, strings)

      <<q, _::binary>> when q in [?", ?'] ->
        scan_string_literal(src, pos, <<q>>, depth, collect, strings)

      _ ->
        scan_expr(src, skip_expr_token(src, pos), depth, collect, strings)
    end
  end

  defp skip_expr_token(src, pos) do
    case peek_bytes(src, pos, 2) do
      "#" <> _ ->
        skip_past(src, pos, "\n")

      "?" <> _ ->
        if pos > 0 and word_char?(:binary.at(src, pos - 1)),
          do: pos + 1,
          else: find_char_literal_end(src, pos + 1)

      <<?~, c, _::binary>> when c in ?a..?z or c in ?A..?Z ->
        find_sigil_end(src, pos + 1)

      _ ->
        pos + 1
    end
  end

  defp scan_string_literal(src, pos, close, depth, collect, strings) do
    start = pos + byte_size(close)

    case scan_string(src, start, close, start, []) do
      {:ok, next, chunks} when collect and close == ~s(") ->
        scan_expr(src, next, depth, collect, [{pos, [chunks]} | strings])

      {:ok, next, chunks} when collect ->
        scan_expr(src, next, depth, collect, [{pos, split_heredoc_lines(src, chunks)} | strings])

      {:ok, next, _} ->
        scan_expr(src, next, depth, collect, strings)

      :error ->
        :error
    end
  end

  # Each heredoc line sorts on its own. Indents and newlines stay out of the chunks, since Elixir
  # needs them. The first line is the rest of the opening `"""` line, which holds no classes.
  defp split_heredoc_lines(src, chunks) do
    {lines, line} = Enum.reduce(chunks, {[], []}, &add_chunk_to_lines(src, &1, &2))

    [Enum.reverse(line) | lines]
    |> Enum.reverse()
    |> tl()
    |> Enum.map(&trim_line_edges(src, &1))
  end

  # `line` is the open line, kept in reverse until a newline closes it.
  defp add_chunk_to_lines(_src, {:dynamic, _, _} = chunk, {lines, line}), do: {lines, [chunk | line]}

  defp add_chunk_to_lines(src, {:static, s, e}, {lines, line}) do
    [first | rest] = split_static_at_newlines(src, s, e)
    Enum.reduce(rest, {lines, [first | line]}, fn seg, {lines, line} -> {[Enum.reverse(line) | lines], [seg]} end)
  end

  # A `\` before the newline joins two lines, so we don't cut there.
  defp split_static_at_newlines(src, s, e) do
    cuts =
      for {i, _} <- :binary.matches(src, "\n", scope: {s, e - s}),
          not String.ends_with?(binary_part(src, s, i - s), ["\\", "\\\r"]),
          do: i

    Enum.zip_with([s | Enum.map(cuts, &(&1 + 1))], cuts ++ [e], &{:static, &1, &2})
  end

  defp trim_line_edges(src, line) do
    line
    |> List.update_at(0, fn {:static, s, e} -> {:static, min(skip_ws(src, s), e), e} end)
    |> List.update_at(-1, fn {:static, s, e} -> {:static, s, max(skip_ws_back(src, e), s)} end)
  end

  defp scan_string(src, pos, _close, _start, _chunks) when pos >= byte_size(src), do: :error

  defp scan_string(src, pos, close, start, chunks) do
    case peek_bytes(src, pos, 2) do
      <<?\\, _>> ->
        scan_string(src, pos + 2, close, start, chunks)

      "\#{" ->
        case scan_expr(src, pos + 2, false) do
          {:ok, next, _} ->
            scan_string(src, next, close, next, [
              {:dynamic, pos, next},
              {:static, start, pos} | chunks
            ])

          :error ->
            :error
        end

      # A heredoc ends only at a `"""` that starts its own line.
      _ ->
        if peek_bytes(src, pos, byte_size(close)) == close and
             (close != ~s(""") or :binary.at(src, skip_ws_back(src, pos) - 1) == ?\n),
           do: {:ok, pos + byte_size(close), Enum.reverse([{:static, start, pos} | chunks])},
           else: scan_string(src, pos + 1, close, start, chunks)
    end
  end

  defp find_char_literal_end(src, pos) do
    if peek_bytes(src, pos, 1) == "\\", do: pos + 2, else: pos + 1
  end

  @pairs %{?( => ?), ?[ => ?], ?{ => ?}, ?< => ?>}

  defp find_sigil_end(src, pos) do
    {_, pos} = take_bytes_while(src, pos, &(&1 in ?a..?z or &1 in ?A..?Z))

    case peek_bytes(src, pos, 3) do
      d when d in [~s("""), "'''"] ->
        skip_past(src, pos + 3, d)

      <<open, _::binary>> ->
        close = Map.get(@pairs, open, open)
        skip_delimited(src, pos + 1, close)

      "" ->
        pos
    end
  end

  defp skip_delimited(src, pos, _close) when pos >= byte_size(src), do: pos

  defp skip_delimited(src, pos, close) do
    case :binary.at(src, pos) do
      ?\\ -> skip_delimited(src, pos + 2, close)
      ^close -> pos + 1
      _ -> skip_delimited(src, pos + 1, close)
    end
  end

  defp word_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  @doc """
  Pairs each string from `scan_expr/3` with the edges that touch it. `src[start..stop)` is the
  expression. The scanner already found the strings, and the AST only tells which of them sit in
  a `<>`. When the expression doesn't parse, we return no strings, so nothing gets sorted.
  """
  @spec find_string_edges(String.t(), non_neg_integer(), non_neg_integer(), [found_string()]) ::
          [{lines :: [[chunk()]], lead :: edge(), trail :: edge()}]
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
