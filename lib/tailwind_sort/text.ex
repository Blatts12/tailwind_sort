defmodule TailwindSort.Text do
  @moduledoc """
  String helpers that most other modules lean on to read class names the way Tailwind does.

  `split_top_level/2` ports `segment.ts` from `tailwindcss/src/utils`. Values inside brackets
  live in `TailwindSort.ArbitraryValue`.
  """

  @doc "Splits `input` on a top-level separator. Separators inside (), [], {} and quotes don't count."
  @spec split_top_level(input :: String.t(), separator :: <<_::8>>) :: [String.t()]
  def split_top_level(input, <<sep>>), do: scan_segments(input, input, sep, 0, 0, [], [])

  # `i` is the byte offset of `rest` in `input`.
  defp scan_segments(<<>>, input, _sep, i, start, _st, parts),
    do: Enum.reverse([binary_part(input, start, i - start) | parts])

  defp scan_segments(<<c, rest::binary>>, input, sep, i, start, [], parts) when c == sep,
    do: scan_segments(rest, input, sep, i + 1, i + 1, [], [binary_part(input, start, i - start) | parts])

  defp scan_segments(<<?\\, _, rest::binary>>, input, sep, i, start, st, parts),
    do: scan_segments(rest, input, sep, i + 2, start, st, parts)

  defp scan_segments(<<?\\>>, input, sep, i, start, st, parts),
    do: scan_segments(<<>>, input, sep, i + 1, start, st, parts)

  defp scan_segments(<<q, rest::binary>>, input, sep, i, start, st, parts) when q in [?", ?'] do
    after_quote = skip_quoted_string(rest, q)
    i = i + 1 + byte_size(rest) - byte_size(after_quote)
    scan_segments(after_quote, input, sep, i, start, st, parts)
  end

  defp scan_segments(<<c, rest::binary>>, input, sep, i, start, st, parts) when c in [?(, ?[, ?{],
    do: scan_segments(rest, input, sep, i + 1, start, [to_closing_bracket(c) | st], parts)

  defp scan_segments(<<c, rest::binary>>, input, sep, i, start, [c | st], parts) when c in [?), ?], ?}],
    do: scan_segments(rest, input, sep, i + 1, start, st, parts)

  defp scan_segments(<<_, rest::binary>>, input, sep, i, start, st, parts),
    do: scan_segments(rest, input, sep, i + 1, start, st, parts)

  defp to_closing_bracket(?(), do: ?)
  defp to_closing_bracket(?[), do: ?]
  defp to_closing_bracket(?{), do: ?}

  @doc "Returns what follows the closing quote `q`. `input` starts right after the opening quote."
  @spec skip_quoted_string(input :: binary(), quote :: byte()) :: binary()
  def skip_quoted_string(<<?\\, _, rest::binary>>, q), do: skip_quoted_string(rest, q)
  def skip_quoted_string(<<q, rest::binary>>, q), do: rest
  def skip_quoted_string(<<_, rest::binary>>, q), do: skip_quoted_string(rest, q)
  def skip_quoted_string(<<>>, _q), do: <<>>

  @doc "Same as matching `^\\d+$`."
  @spec digits?(String.t()) :: boolean()
  def digits?(<<c, rest::binary>>) when c in ?0..?9, do: rest == "" or digits?(rest)
  def digits?(_), do: false

  @doc "Same as matching `^\\d*\\.\\d+$`."
  @spec decimal?(String.t()) :: boolean()
  def decimal?(str) do
    case :binary.split(str, ".") do
      [int, frac] -> (int == "" or digits?(int)) and digits?(frac)
      _ -> false
    end
  end

  @doc "Checks for a number followed by `%`. `number?` decides what counts as the number."
  @spec percent_value?(String.t(), (String.t() -> boolean())) :: boolean()
  def percent_value?(v, number?), do: String.ends_with?(v, "%") and number?.(binary_part(v, 0, byte_size(v) - 1))

  @doc "Port of isValidSpacingMultiplier. The value must be a multiple of 0.25, written the way JS prints numbers."
  @spec quarter_multiple?(String.t()) :: boolean()
  def quarter_multiple?(v) do
    case Float.parse(v) do
      {f, ""} -> Float.to_string(f) == v and f * 4 == Float.round(f * 4)
      _ -> false
    end
  end

  @doc "Same as matching `^[a-zA-Z0-9_.%-]+$`."
  @spec named_value?(String.t()) :: boolean()
  def named_value?(<<c, rest::binary>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?., ?%, ?-],
    do: rest == "" or named_value?(rest)

  def named_value?(_), do: false

  @doc "Matches the bytes that `\\s` matches in a regex."
  defguard is_whitespace(c) when c in [?\s, ?\t, ?\n, ?\v, ?\f, ?\r]

  @spec trim_leading_whitespace(String.t()) :: String.t()
  def trim_leading_whitespace(<<c, rest::binary>>) when is_whitespace(c), do: trim_leading_whitespace(rest)
  def trim_leading_whitespace(str), do: str

  @spec trim_trailing_whitespace(String.t()) :: String.t()
  def trim_trailing_whitespace(str), do: binary_part(str, 0, find_trailing_whitespace_start(str, byte_size(str)))

  defp find_trailing_whitespace_start(str, i) when i > 0 do
    if is_whitespace(:binary.at(str, i - 1)), do: find_trailing_whitespace_start(str, i - 1), else: i
  end

  defp find_trailing_whitespace_start(_str, 0), do: 0

  @doc "Port of utils/compare.ts. It compares strings byte by byte, but compares runs of digits as numbers."
  @spec compare_alnum(String.t(), String.t()) :: integer()
  def compare_alnum(a, z), do: compare_alnum_from(a, z, 0, min(byte_size(a), byte_size(z)))

  defp compare_alnum_from(a, z, i, min) when i >= min, do: byte_size(a) - byte_size(z)

  defp compare_alnum_from(a, z, i, min) do
    ac = :binary.at(a, i)
    zc = :binary.at(z, i)

    if digit_char?(ac) and digit_char?(zc) do
      an = take_digit_run(a, i)
      zn = take_digit_run(z, i)

      case String.to_integer(an) - String.to_integer(zn) do
        0 when an < zn -> -1
        0 when an > zn -> 1
        0 -> compare_alnum_from(a, z, i + 1, min)
        diff -> diff
      end
    else
      if ac == zc, do: compare_alnum_from(a, z, i + 1, min), else: ac - zc
    end
  end

  defp digit_char?(c), do: c >= ?0 and c <= ?9

  defp take_digit_run(s, i), do: binary_part(s, i, find_digit_run_end(s, i) - i)

  defp find_digit_run_end(s, i) do
    if i < byte_size(s) and digit_char?(:binary.at(s, i)), do: find_digit_run_end(s, i + 1), else: i
  end
end
