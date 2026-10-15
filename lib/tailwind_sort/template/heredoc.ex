defmodule TailwindSort.Template.Heredoc do
  @moduledoc """
  Splits a heredoc string inside `class={...}` into lines, so each line sorts on its own.
  """

  import TailwindSort.Template.ByteScan

  alias TailwindSort.Template.ElixirExpr

  @doc """
  Cuts the heredoc's chunks at each newline. Indents and newlines stay out of the chunks, since
  Elixir needs them. The first line is the rest of the opening `\"""` line, which holds no
  classes, so we drop it.
  """
  @spec split_heredoc_lines(String.t(), [ElixirExpr.chunk()]) :: [[ElixirExpr.chunk()]]
  def split_heredoc_lines(src, chunks) do
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
end
