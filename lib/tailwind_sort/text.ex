defmodule TailwindSort.Text do
  @moduledoc """
  String helpers that most other modules lean on to read class names the way Tailwind does.

  These are ports of `segment.ts`, `is-valid-arbitrary.ts` and `decode-arbitrary-value.ts`
  from `tailwindcss/src/utils`.
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

  # Returns what follows the closing quote, or `<<>>` when the string never closes.
  defp skip_quoted_string(<<?\\, _, rest::binary>>, q), do: skip_quoted_string(rest, q)
  defp skip_quoted_string(<<q, rest::binary>>, q), do: rest
  defp skip_quoted_string(<<_, rest::binary>>, q), do: skip_quoted_string(rest, q)
  defp skip_quoted_string(<<>>, _q), do: <<>>

  @doc "Port of isValidArbitrary. Brackets must balance, and a top-level `;` makes the value invalid."
  @spec valid_arbitrary_value?(value :: String.t()) :: boolean()
  def valid_arbitrary_value?(input), do: scan_arbitrary_value(input, [])

  defp scan_arbitrary_value(<<>>, _st), do: true
  defp scan_arbitrary_value(<<?\\, _, rest::binary>>, st), do: scan_arbitrary_value(rest, st)
  defp scan_arbitrary_value(<<?\\>>, _st), do: true

  defp scan_arbitrary_value(<<q, rest::binary>>, st) when q in [?", ?'],
    do: scan_arbitrary_value(skip_quoted_string(rest, q), st)

  defp scan_arbitrary_value(<<?(, rest::binary>>, st), do: scan_arbitrary_value(rest, [?) | st])
  defp scan_arbitrary_value(<<?[, rest::binary>>, st), do: scan_arbitrary_value(rest, [?] | st])
  defp scan_arbitrary_value(<<c, _::binary>>, []) when c in [?), ?], ?}, ?;], do: false

  defp scan_arbitrary_value(<<c, rest::binary>>, [c | st]) when c in [?), ?], ?}], do: scan_arbitrary_value(rest, st)

  defp scan_arbitrary_value(<<_, rest::binary>>, st), do: scan_arbitrary_value(rest, st)

  @doc """
  Simplified port of decodeArbitraryValue. An `_` becomes a space, unless you escape it as `\\_`.
  The contents of `url(...)` stay as written. The first argument of `var(...)` or `theme(...)`
  keeps its underscores.
  """
  @spec decode_arbitrary_value(value :: String.t()) :: String.t()
  def decode_arbitrary_value(input) do
    if String.contains?(input, "("),
      do: decode_function_calls(input, []),
      else: replace_underscores(input, false)
  end

  defp decode_function_calls(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A run of name bytes is a function name when `(` follows it. Otherwise no suffix of the run
  # can be one either, so we copy the whole run and move on.
  defp decode_function_calls(input, acc) do
    {name, rest} = take_function_name(input, 0)

    case rest do
      "(" <> after_paren ->
        decode_function_call(name, after_paren, acc)

      _ when name != "" ->
        decode_function_calls(rest, [replace_underscores(name, false) | acc])

      _ ->
        {plain, rest} = take_plain_bytes(rest, 0)
        decode_function_calls(rest, [plain | acc])
    end
  end

  defp take_function_name(input, i) do
    case input do
      <<_::binary-size(^i), c, _::binary>>
      when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-] ->
        take_function_name(input, i + 1)

      <<name::binary-size(^i), rest::binary>> ->
        {name, rest}
    end
  end

  # Bytes that can't start a function name or call. None of them is `_`, so they need no decoding.
  defp take_plain_bytes(input, i) do
    case input do
      <<_::binary-size(^i), c, _::binary>>
      when c not in ?a..?z and c not in ?A..?Z and c not in ?0..?9 and c not in [?_, ?-, ?(] ->
        take_plain_bytes(input, i + 1)

      <<plain::binary-size(^i), rest::binary>> ->
        {plain, rest}
    end
  end

  defp decode_function_call(name, input, acc) do
    {inner, rest} = take_balanced_parens(input, 1, [])

    decoded_inner =
      cond do
        name == "url" or String.ends_with?(name, "_url") ->
          inner

        name in ["var", "theme"] or String.ends_with?(name, "_var") or
            String.ends_with?(name, "_theme") ->
          [first | others] = split_top_level(inner, ",")

          Enum.join(
            [
              replace_underscores(first, true)
              | Enum.map(others, &decode_arbitrary_value/1)
            ],
            ","
          )

        true ->
          decode_arbitrary_value(inner)
      end

    decode_function_calls(rest, [[replace_underscores(name, false), "(", decoded_inner, ")"] | acc])
  end

  # Returns `{inner, rest}`. `inner` drops the closing paren and `rest` starts right after it.
  defp take_balanced_parens(<<>>, _depth, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_balanced_parens(<<?), rest::binary>>, 1, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_balanced_parens(<<?), rest::binary>>, d, acc), do: take_balanced_parens(rest, d - 1, [?) | acc])

  defp take_balanced_parens(<<?(, rest::binary>>, d, acc), do: take_balanced_parens(rest, d + 1, [?( | acc])

  defp take_balanced_parens(<<c, rest::binary>>, d, acc), do: take_balanced_parens(rest, d, [c | acc])

  defp replace_underscores(input, keep_underscores?) do
    if String.contains?(input, "_"),
      do: replace_underscore_bytes(input, if(keep_underscores?, do: ?_, else: ?\s), []),
      else: input
  end

  defp replace_underscore_bytes(<<>>, _space, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp replace_underscore_bytes(<<?\\, ?_, rest::binary>>, space, acc),
    do: replace_underscore_bytes(rest, space, [?_ | acc])

  defp replace_underscore_bytes(<<?_, rest::binary>>, space, acc),
    do: replace_underscore_bytes(rest, space, [space | acc])

  defp replace_underscore_bytes(<<c, rest::binary>>, space, acc), do: replace_underscore_bytes(rest, space, [c | acc])

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
