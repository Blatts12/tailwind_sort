defmodule TailwindSort.Template.ElixirExpr do
  @moduledoc ~S"""
  Scans the Elixir expression inside a template's `{...}`, like the one in `class={...}`.

  `scan_expr/3` finds where the expression ends and where its double-quoted strings sit, as byte
  offsets. A string comes back as lines of chunks. `#{}` splits a line into `:static` and
  `:dynamic` chunks, and a heredoc has one line per source line, as split by
  `TailwindSort.Template.Heredoc`.
  """

  import TailwindSort.Template.ByteScan

  alias TailwindSort.Template.Heredoc

  @type chunk :: {:static | :dynamic, non_neg_integer(), non_neg_integer()}
  @type found_string :: {open_quote :: non_neg_integer(), lines :: [[chunk()]]}

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

      {:ok, next, chunks} when collect and close == ~s(""") ->
        scan_expr(src, next, depth, collect, [{pos, Heredoc.split_heredoc_lines(src, chunks)} | strings])

      {:ok, next, _} ->
        scan_expr(src, next, depth, collect, strings)

      :error ->
        :error
    end
  end

  defp scan_string(src, pos, _close, _start, _chunks) when pos >= byte_size(src), do: :error

  defp scan_string(src, pos, close, start, chunks) do
    case src do
      <<_::binary-size(^pos), c, _::binary>> when c not in [?\\, ?#, ?", ?'] ->
        scan_string(src, pos + 1, close, start, chunks)

      <<_::binary-size(^pos), ?\\, _, _::binary>> ->
        scan_string(src, pos + 2, close, start, chunks)

      <<_::binary-size(^pos), "\#{", _::binary>> ->
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
end
