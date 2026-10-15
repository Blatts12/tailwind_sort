defmodule TailwindSort.Template.ByteScan do
  @moduledoc """
  Byte offset helpers for the template and Elixir expression scanners.

  Each one takes the whole source and a byte offset into it, and returns a new offset or a slice.
  """

  @doc "Returns the offset just past the next `pattern`, or the end of `src` when there is none."
  @spec skip_past(String.t(), non_neg_integer(), String.t()) :: non_neg_integer()
  def skip_past(src, pos, pattern) do
    case :binary.match(src, pattern, scope: {pos, byte_size(src) - pos}) do
      {i, len} -> i + len
      :nomatch -> byte_size(src)
    end
  end

  @doc "Returns the offset of the next `pattern`, or the end of `src` when there is none."
  @spec skip_to(String.t(), non_neg_integer(), String.t() | [String.t()] | :binary.cp()) :: non_neg_integer()
  def skip_to(src, pos, pattern) do
    case :binary.match(src, pattern, scope: {pos, byte_size(src) - pos}) do
      {i, _} -> i
      :nomatch -> byte_size(src)
    end
  end

  @doc "Returns up to `n` bytes from `pos`. Past the end you get an empty string."
  @spec peek_bytes(String.t(), non_neg_integer(), integer()) :: String.t()
  def peek_bytes(src, pos, n) when pos >= byte_size(src) or n <= 0, do: ""
  def peek_bytes(src, pos, n), do: binary_part(src, pos, min(n, byte_size(src) - pos))

  @doc "Skips spaces, tabs and newlines forward."
  @spec skip_ws(String.t(), non_neg_integer()) :: non_neg_integer()
  def skip_ws(src, pos) do
    case src do
      <<_::binary-size(^pos), c, _::binary>> when c in ~c" \t\r\n" -> skip_ws(src, pos + 1)
      _ -> pos
    end
  end

  @doc "Skips spaces and tabs backward. It stops at a newline, so it never leaves the current line."
  @spec skip_ws_back(String.t(), non_neg_integer()) :: non_neg_integer()
  def skip_ws_back(src, pos) do
    if pos > 0 and :binary.at(src, pos - 1) in ~c" \t\r",
      do: skip_ws_back(src, pos - 1),
      else: pos
  end

  @doc "Takes bytes while `fun` returns true. Returns the bytes taken and the offset after them."
  @spec take_bytes_while(String.t(), non_neg_integer(), (byte() -> boolean())) :: {String.t(), non_neg_integer()}
  def take_bytes_while(src, pos, fun) do
    stop = find_take_stop(src, pos, fun)
    {binary_part(src, pos, stop - pos), stop}
  end

  defp find_take_stop(src, pos, fun) do
    case src do
      <<_::binary-size(^pos), c, _::binary>> -> if fun.(c), do: find_take_stop(src, pos + 1, fun), else: pos
      _ -> pos
    end
  end
end
