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

  `TailwindSort.Template.ElixirExpr` reads the Elixir inside `{...}`.
  """

  import TailwindSort.Template.ByteScan

  alias TailwindSort.Design
  alias TailwindSort.Sorter
  alias TailwindSort.Template.ElixirExpr
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
        case ElixirExpr.scan_expr(src, pos + 1, false) do
          {:ok, next, _} -> scan_text(src, next, ctx, edits)
          :error -> scan_text(src, pos + 1, ctx, edits)
        end

      _ ->
        scan_text(src, pos + 1, ctx, edits)
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
        case ElixirExpr.scan_expr(src, pos + 1, false) do
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
        case ElixirExpr.scan_expr(src, pos + 1, true) do
          {:ok, next, strings} when sort? ->
            edits =
              src
              |> ElixirExpr.find_string_edges(pos + 1, next - 1, strings)
              |> Enum.reduce(edits, &build_string_edits(src, &1, ctx, &2))

            scan_attributes(src, next, ctx, edits)

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
        case ElixirExpr.scan_expr(src, pos + 1, false) do
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

  # Only the first line touches what comes before the string, and only the last line what follows it.
  defp build_string_edits(src, {lines, lead, trail}, ctx, edits) do
    last = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reduce(edits, fn {chunks, i}, acc ->
      build_chunk_edits(src, chunks, ctx, acc, if(i == 0, do: lead, else: :free), if(i == last, do: trail, else: :free))
    end)
  end

  # `lead` and `trail` are the string's edges, as in `t:TailwindSort.Template.ElixirExpr.edge/0`.
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
end
