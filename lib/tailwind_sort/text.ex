defmodule TailwindSort.Text do
  @moduledoc false
  # Ports of segment.ts, is-valid-arbitrary.ts and decode-arbitrary-value.ts from tailwindcss/src/utils.

  @doc "Splits `input` on a top-level separator. Separators inside (), [], {} and quotes don't count."
  def split_top_level(input, <<sep>>), do: scan_segments(input, sep, [], [], [])

  defp scan_segments(<<>>, _sep, _st, cur, parts), do: Enum.reverse([build_segment(cur) | parts])

  defp scan_segments(<<c, rest::binary>>, sep, [], cur, parts) when c == sep,
    do: scan_segments(rest, sep, [], [], [build_segment(cur) | parts])

  defp scan_segments(<<?\\, n, rest::binary>>, sep, st, cur, parts),
    do: scan_segments(rest, sep, st, [n, ?\\ | cur], parts)

  defp scan_segments(<<?\\>>, sep, st, cur, parts), do: scan_segments(<<>>, sep, st, [?\\ | cur], parts)

  defp scan_segments(<<q, rest::binary>>, sep, st, cur, parts) when q in [?", ?'] do
    {str, rest} = take_quoted_string(rest, q, [q])
    scan_segments(rest, sep, st, [str | cur], parts)
  end

  defp scan_segments(<<c, rest::binary>>, sep, st, cur, parts) when c in [?(, ?[, ?{],
    do: scan_segments(rest, sep, [to_closing_bracket(c) | st], [c | cur], parts)

  defp scan_segments(<<c, rest::binary>>, sep, [c | st], cur, parts) when c in [?), ?], ?}],
    do: scan_segments(rest, sep, st, [c | cur], parts)

  defp scan_segments(<<c, rest::binary>>, sep, st, cur, parts), do: scan_segments(rest, sep, st, [c | cur], parts)

  defp to_closing_bracket(?(), do: ?)
  defp to_closing_bracket(?[), do: ?]
  defp to_closing_bracket(?{), do: ?}

  # Returns `{chunk, rest}`. The chunk includes the closing quote when the string has one.
  defp take_quoted_string(<<?\\, n, rest::binary>>, q, acc), do: take_quoted_string(rest, q, [acc, ?\\, n])

  defp take_quoted_string(<<q, rest::binary>>, q, acc), do: {wrap_chunk([acc, q]), rest}
  defp take_quoted_string(<<c, rest::binary>>, q, acc), do: take_quoted_string(rest, q, [acc, c])
  defp take_quoted_string(<<>>, _q, acc), do: {wrap_chunk(acc), <<>>}

  # `cur` is a reversed list, so we push the whole string as one element. Reversing keeps it intact.
  defp wrap_chunk(iodata), do: {:chunk, IO.iodata_to_binary(iodata)}

  defp build_segment(cur) do
    cur
    |> Enum.reverse()
    |> Enum.map(fn
      {:chunk, b} -> b
      c -> c
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Port of isValidArbitrary. Brackets must balance, and a top-level `;` makes the value invalid."
  def valid_arbitrary_value?(input), do: scan_arbitrary_value(input, [])

  defp scan_arbitrary_value(<<>>, _st), do: true
  defp scan_arbitrary_value(<<?\\, _, rest::binary>>, st), do: scan_arbitrary_value(rest, st)
  defp scan_arbitrary_value(<<?\\>>, _st), do: true

  defp scan_arbitrary_value(<<q, rest::binary>>, st) when q in [?", ?'] do
    {_, rest} = take_quoted_string(rest, q, [])
    scan_arbitrary_value(rest, st)
  end

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
  def decode_arbitrary_value(input) do
    if String.contains?(input, "("),
      do: decode_function_calls(input, []),
      else: replace_underscores(input, false)
  end

  defp decode_function_calls(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_function_calls(input, acc) do
    case Regex.run(~r/^([a-zA-Z0-9_-]*)\(/, input) do
      [whole, name] ->
        {inner, rest} =
          take_balanced_parens(
            binary_part(input, byte_size(whole), byte_size(input) - byte_size(whole)),
            1,
            []
          )

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

        decode_function_calls(rest, [
          [replace_underscores(name, false), "(", decoded_inner, ")"] | acc
        ])

      nil ->
        <<c::utf8, rest::binary>> = input
        decode_function_calls(rest, [replace_underscores(<<c::utf8>>, false) | acc])
    end
  end

  # Returns `{inner, rest}`. `inner` drops the closing paren and `rest` starts right after it.
  defp take_balanced_parens(<<>>, _depth, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_balanced_parens(<<?), rest::binary>>, 1, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_balanced_parens(<<?), rest::binary>>, d, acc), do: take_balanced_parens(rest, d - 1, [?) | acc])

  defp take_balanced_parens(<<?(, rest::binary>>, d, acc), do: take_balanced_parens(rest, d + 1, [?( | acc])

  defp take_balanced_parens(<<c, rest::binary>>, d, acc), do: take_balanced_parens(rest, d, [c | acc])

  defp replace_underscores(input, keep_underscores?) do
    String.replace(input, ~r/\\_|_/, fn
      "\\_" -> "_"
      "_" -> if keep_underscores?, do: "_", else: " "
    end)
  end

  @doc "Port of utils/compare.ts. It compares strings byte by byte, but compares runs of digits as numbers."
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

  defp take_digit_run(s, i) do
    [run] = Regex.run(~r/^\d+/, binary_part(s, i, byte_size(s) - i))
    run
  end
end
