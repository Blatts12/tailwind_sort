defmodule TailwindSort.Template do
  @moduledoc ~S"""
  Finds class attributes in HEEx and Hologram templates and sorts them in place.

  Only the attribute contents change. Everything else comes back untouched.

    * `class="..."` sorts the whole value.
    * `class={...}` sorts every Elixir string literal inside. `#{}` splits a literal into
      chunks, and we sort each chunk around the interpolation.
    * In a heredoc, each line sorts on its own and keeps its indent.
    * Next to `<>`, a string keeps its whitespace. A class touching `<>` with no space
      stays in place, since it may glue onto the other side.
    * `class="a {@b} c"` uses the same chunking, for Hologram only (`interpolate_quoted: true`).
  """

  alias TailwindSort.Design
  alias TailwindSort.Sorter
  alias TailwindSort.Text

  @spec sort_class_attributes(template :: String.t(), Design.t(), keyword()) :: String.t()
  def sort_class_attributes(src, design, opts) do
    ctx = %{
      d: design,
      attrs: build_attribute_matcher(Keyword.get(opts, :attributes, ["class"])),
      interpolate_quoted: Keyword.get(opts, :interpolate_quoted, false),
      sort_opts: Keyword.take(opts, [:remove_duplicates])
    }

    case scan_text(src, 0, ctx, []) do
      [] -> src
      edits -> apply_edits(src, Enum.sort(edits), 0, [])
    end
  end

  defp build_attribute_matcher(entries) do
    {names, regexes} = Enum.split_with(List.wrap(entries), &is_binary/1)
    names = MapSet.new(names)
    fn name -> MapSet.member?(names, name) or Enum.any?(regexes, &Regex.match?(&1, name)) end
  end

  defp apply_edits(src, [], pos, acc), do: IO.iodata_to_binary([acc, binary_part(src, pos, byte_size(src) - pos)])

  defp apply_edits(src, [{start, stop, new} | rest], pos, acc),
    do: apply_edits(src, rest, stop, [acc, binary_part(src, pos, start - pos), new])

  defp scan_text(src, pos, _ctx, edits) when pos >= byte_size(src), do: edits

  defp scan_text(src, pos, ctx, edits) do
    rest = binary_part(src, pos, byte_size(src) - pos)

    case rest do
      "<!--" <> _ ->
        scan_text(src, skip_past(src, pos, "-->"), ctx, edits)

      "<%!--" <> _ ->
        scan_text(src, skip_past(src, pos, "--%>"), ctx, edits)

      "<%" <> _ ->
        scan_text(src, skip_past(src, pos, "%>"), ctx, edits)

      "</" <> _ ->
        scan_text(src, skip_past(src, pos, ">"), ctx, edits)

      <<?<, c, _::binary>> when c in ?a..?z or c in ?A..?Z or c in [?., ?:] ->
        scan_tag(src, pos + 1, ctx, edits)

      "{" <> _ ->
        case scan_expr(src, pos + 1, 1, false, []) do
          {:ok, next, _} -> scan_text(src, next, ctx, edits)
          :error -> scan_text(src, pos + 1, ctx, edits)
        end

      _ ->
        scan_text(src, pos + 1, ctx, edits)
    end
  end

  defp skip_past(src, pos, pattern) do
    case :binary.match(src, pattern, scope: {pos, byte_size(src) - pos}) do
      {i, len} -> i + len
      :nomatch -> byte_size(src)
    end
  end

  defp scan_tag(src, pos, ctx, edits) do
    {name, pos} = take_bytes_while(src, pos, &(&1 not in ~c" \t\r\n/>"))

    case scan_attributes(src, pos, ctx, edits) do
      {:ok, next, edits} ->
        if String.downcase(name) in ["script", "style"],
          do: scan_text(src, skip_raw_text(src, next, String.downcase(name)), ctx, edits),
          else: scan_text(src, next, ctx, edits)

      {:eof, edits} ->
        edits
    end
  end

  defp skip_raw_text(src, pos, name) do
    case :binary.match(src, "</" <> name, scope: {pos, byte_size(src) - pos}) do
      {i, _} -> i
      :nomatch -> byte_size(src)
    end
  end

  defp scan_attributes(src, pos, ctx, edits) do
    pos = skip_ws(src, pos)

    case peek_bytes(src, pos, 2) do
      "" ->
        {:eof, edits}

      ">" <> _ ->
        {:ok, pos + 1, edits}

      "/>" ->
        {:ok, pos + 2, edits}

      "<%" ->
        scan_attributes(src, skip_past(src, pos, "%>"), ctx, edits)

      "{" <> _ ->
        case scan_expr(src, pos + 1, 1, false, []) do
          {:ok, next, _} -> scan_attributes(src, next, ctx, edits)
          :error -> {:eof, edits}
        end

      _ ->
        {name, after_name} = take_bytes_while(src, pos, &(&1 not in ~c" \t\r\n=>/"))
        after_name = if after_name == pos, do: pos + 1, else: after_name
        value_pos = skip_ws(src, after_name)

        if peek_bytes(src, value_pos, 1) == "=" do
          scan_attribute_value(src, skip_ws(src, value_pos + 1), ctx.attrs.(name), ctx, edits)
        else
          scan_attributes(src, after_name, ctx, edits)
        end
    end
  end

  defp scan_attribute_value(src, pos, sort?, ctx, edits) do
    case peek_bytes(src, pos, 1) do
      q when q in ["\"", "'"] ->
        case scan_quoted_value(
               src,
               pos + 1,
               :binary.first(q),
               ctx.interpolate_quoted,
               pos + 1,
               []
             ) do
          {:ok, next, chunks} ->
            edits = if sort?, do: build_chunk_edits(src, chunks, ctx, edits), else: edits
            scan_attributes(src, next, ctx, edits)

          :error ->
            {:eof, edits}
        end

      "{" ->
        case scan_expr(src, pos + 1, 1, true, []) do
          {:ok, next, strings} when sort? ->
            scan_attributes(src, next, ctx, build_expr_edits(src, pos + 1, next - 1, strings, ctx, edits))

          {:ok, next, _} ->
            scan_attributes(src, next, ctx, edits)

          :error ->
            {:eof, edits}
        end

      "" ->
        {:eof, edits}

      _ ->
        {_, next} = take_bytes_while(src, pos, &(&1 not in ~c" \t\r\n>"))

        edits =
          if sort?, do: build_chunk_edits(src, [{:static, pos, next}], ctx, edits), else: edits

        scan_attributes(src, next, ctx, edits)
    end
  end

  defp scan_quoted_value(src, pos, _q, _interp, _start, _chunks) when pos >= byte_size(src), do: :error

  defp scan_quoted_value(src, pos, q, interp, start, chunks) do
    case :binary.at(src, pos) do
      ^q ->
        {:ok, pos + 1, Enum.reverse([{:static, start, pos} | chunks])}

      ?{ when interp ->
        case scan_expr(src, pos + 1, 1, false, []) do
          {:ok, next, _} ->
            scan_quoted_value(src, next, q, interp, next, [
              {:dynamic, pos, next},
              {:static, start, pos} | chunks
            ])

          :error ->
            :error
        end

      _ ->
        scan_quoted_value(src, pos + 1, q, interp, start, chunks)
    end
  end

  # The scanner finds the strings in `src[start..stop)`. The AST only tells which of them sit in a `<>`.
  defp build_expr_edits(src, start, stop, strings, ctx, edits) do
    expr = binary_part(src, start, stop - start)
    encode = &{:ok, {:__block__, &2, [&1]}}

    case Code.string_to_quoted(expr, columns: true, emit_warnings: false, literal_encoder: encode) do
      {:ok, ast} ->
        joins = collect_joined_edges(ast, :free, :free, %{})

        for {open, lines} <- strings,
            # The AST counts columns in codepoints, so UTF-8 continuation bytes don't count.
            before = :binary.split(binary_part(src, start, open - start), "\n", [:global]),
            column = Enum.count(:binary.bin_to_list(List.last(before)), &(&1 not in 0x80..0xBF)) + 1,
            {lead, trail} = Map.get(joins, {length(before), column}, {:free, :free}),
            last = length(lines) - 1,
            {chunks, i} <- Enum.with_index(lines),
            [reduce: edits] do
          acc ->
            build_chunk_edits(
              src,
              chunks,
              ctx,
              acc,
              if(i == 0, do: lead, else: :free),
              if(i == last, do: trail, else: :free)
            )
        end

      {:error, _} ->
        edits
    end
  end

  # `lead` and `trail` say what touches the start and end of the string: `:free` for nothing,
  # `:space` for `<>` with whitespace on the other side, `:glue` for `<>` with anything else.
  defp build_chunk_edits(src, chunks, ctx, edits, lead \\ :free, trail \\ :free) do
    statics = for {:static, _, _} = c <- chunks, do: c
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.reduce(edits, fn
      {{:dynamic, _, _}, _}, acc ->
        acc

      {{:static, s, e}, i}, acc ->
        old = binary_part(src, s, e - s)

        opts =
          ctx.sort_opts ++
            [
              ignore_first: Text.trim_leading_whitespace(old) == old and (i > 0 or lead == :glue),
              ignore_last: Text.trim_trailing_whitespace(old) == old and (i < last or trail == :glue),
              collapse_start: i == 0 and lead == :free,
              collapse_end: i == last and trail == :free
            ]

        # A heredoc line may hold a `"""`, and moving it to the line start would close the heredoc.
        new =
          if statics == [] or String.contains?(old, ["\\", ~s(""")]),
            do: old,
            else: Sorter.sort_class_string(old, ctx.d, opts)

        if new == old, do: acc, else: [{s, e, new} | acc]
    end)
  end

  # Scans an Elixir expression from just after an opening `{` to the matching `}`.
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

  # Collects `{open_quote_pos, lines}` per double-quoted string, where each line is a chunk list.
  defp scan_string_literal(src, pos, close, depth, collect, strings) do
    start = pos + byte_size(close)

    case scan_string(src, start, close, start, []) do
      {:ok, next, chunks} when collect and close == ~s(") ->
        scan_expr(src, next, depth, collect, [{pos, [chunks]} | strings])

      # Each heredoc line sorts on its own. Indents and newlines stay out of the chunks, since
      # Elixir needs them. A `\` before the newline joins two lines, so we don't cut there.
      # The first line is the rest of the opening `"""` line, which holds no classes.
      {:ok, next, chunks} when collect ->
        {lines, line} =
          Enum.reduce(chunks, {[], []}, fn
            {:dynamic, _, _} = chunk, {lines, line} ->
              {lines, [chunk | line]}

            {:static, s, e}, {lines, line} ->
              cuts =
                for {i, _} <- :binary.matches(src, "\n", scope: {s, e - s}),
                    not String.ends_with?(binary_part(src, s, i - s), ["\\", "\\\r"]),
                    do: i

              [first | rest] = Enum.zip_with([s | Enum.map(cuts, &(&1 + 1))], cuts ++ [e], &{:static, &1, &2})

              Enum.reduce(rest, {lines, [first | line]}, fn seg, {lines, line} ->
                {[Enum.reverse(line) | lines], [seg]}
              end)
          end)

        lines =
          [Enum.reverse(line) | lines]
          |> Enum.reverse()
          |> tl()
          |> Enum.map(fn line ->
            line
            |> List.update_at(0, fn {:static, s, e} -> {:static, min(skip_ws(src, s), e), e} end)
            |> List.update_at(-1, fn {:static, s, e} -> {:static, s, max(skip_ws_back(src, e), s)} end)
          end)

        scan_expr(src, next, depth, collect, [{pos, lines} | strings])

      {:ok, next, _} ->
        scan_expr(src, next, depth, collect, strings)

      :error ->
        :error
    end
  end

  # Maps `{line, column}` of each string inside a `<>` to its `{lead, trail}`, as in
  # build_chunk_edits. Like canCollapseWhitespaceIn in prettier-plugin-tailwindcss, a string
  # anywhere inside an operand counts, so `@a <> if(@b, do: " p-4")` keeps its space.
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

  defp skip_ws_back(src, pos) do
    if pos > 0 and :binary.at(src, pos - 1) in ~c" \t\r",
      do: skip_ws_back(src, pos - 1),
      else: pos
  end

  defp scan_string(src, pos, _close, _start, _chunks) when pos >= byte_size(src), do: :error

  defp scan_string(src, pos, close, start, chunks) do
    case peek_bytes(src, pos, 2) do
      <<?\\, _>> ->
        scan_string(src, pos + 2, close, start, chunks)

      "\#{" ->
        case scan_expr(src, pos + 2, 1, false, []) do
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

  defp peek_bytes(src, pos, n) when pos >= byte_size(src) or n <= 0, do: ""
  defp peek_bytes(src, pos, n), do: binary_part(src, pos, min(n, byte_size(src) - pos))

  defp skip_ws(src, pos) do
    {_, pos} = take_bytes_while(src, pos, &(&1 in ~c" \t\r\n"))
    pos
  end

  defp take_bytes_while(src, pos, fun) do
    stop = find_take_stop(src, pos, fun)
    {binary_part(src, pos, stop - pos), stop}
  end

  defp find_take_stop(src, pos, fun) do
    if pos < byte_size(src) and fun.(:binary.at(src, pos)),
      do: find_take_stop(src, pos + 1, fun),
      else: pos
  end
end
