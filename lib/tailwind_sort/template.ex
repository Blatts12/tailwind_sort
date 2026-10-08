defmodule TailwindSort.Template do
  @moduledoc ~S"""
  Finds class attributes in HEEx and Hologram templates and sorts them in place.

  Only the attribute contents change. Everything else comes back untouched.

    * `class="..."` sorts the whole value.
    * `class={...}` sorts every Elixir string literal inside. `#{}` splits a literal into
      chunks, and we sort each chunk around the interpolation.
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

  # Entries are exact names or regexes. A regex runs against the whole attribute name as written.
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
          {:ok, next, strings} ->
            edits =
              if sort?,
                do: Enum.reduce(strings, edits, &build_chunk_edits(src, &1, ctx, &2)),
                else: edits

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

  # Returns the chunks in order. Each one is `{:static, start, stop}` or `{:dynamic, start, stop}`.
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

  defp build_chunk_edits(src, chunks, ctx, edits) do
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
              ignore_first: i > 0 and Text.trim_leading_whitespace(old) == old,
              ignore_last: i < last and Text.trim_trailing_whitespace(old) == old,
              collapse_start: i == 0,
              collapse_end: i == last
            ]

        new =
          if statics == [] or String.contains?(old, "\\"),
            do: old,
            else: Sorter.sort_class_string(old, ctx.d, opts)

        if new == old, do: acc, else: [{s, e, new} | acc]
    end)
  end

  # Scans an Elixir expression from just after an opening `{` to the matching `}`.
  # Returns `{:ok, pos_after_brace, string_literals}`, where each literal is a chunk list.

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
        scan_expr(src, skip_past(src, pos + 3, ~s(""")), depth, collect, strings)

      <<q, _::binary>> when q in [?", ?'] ->
        case scan_string(src, pos + 1, q, pos + 1, []) do
          {:ok, next, chunks} when collect and q == ?" -> scan_expr(src, next, depth, collect, [chunks | strings])
          {:ok, next, _} -> scan_expr(src, next, depth, collect, strings)
          :error -> :error
        end

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

  defp scan_string(src, pos, _q, _start, _chunks) when pos >= byte_size(src), do: :error

  defp scan_string(src, pos, q, start, chunks) do
    case binary_part(src, pos, min(2, byte_size(src) - pos)) do
      <<?\\, _>> ->
        scan_string(src, pos + 2, q, start, chunks)

      "\#{" ->
        case scan_expr(src, pos + 2, 1, false, []) do
          {:ok, next, _} ->
            scan_string(src, next, q, next, [
              {:dynamic, pos, next},
              {:static, start, pos} | chunks
            ])

          :error ->
            :error
        end

      <<^q, _::binary>> ->
        {:ok, pos + 1, Enum.reverse([{:static, start, pos} | chunks])}

      _ ->
        scan_string(src, pos + 1, q, start, chunks)
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
