defmodule TailwindSort.ArbitraryValue do
  @moduledoc """
  Reads the value inside brackets, like the `#fff` in `bg-[#fff]` or `color:red` in `[color:red]`.

  These are ports of `is-valid-arbitrary.ts` and `decode-arbitrary-value.ts` from
  `tailwindcss/src/utils`.
  """

  alias TailwindSort.Text

  @doc "Port of isValidArbitrary. Brackets must balance, and a top-level `;` makes the value invalid."
  @spec valid_arbitrary_value?(value :: String.t()) :: boolean()
  def valid_arbitrary_value?(input), do: scan_arbitrary_value(input, [])

  defp scan_arbitrary_value(<<>>, _st), do: true
  defp scan_arbitrary_value(<<?\\, _, rest::binary>>, st), do: scan_arbitrary_value(rest, st)
  defp scan_arbitrary_value(<<?\\>>, _st), do: true

  defp scan_arbitrary_value(<<q, rest::binary>>, st) when q in [?", ?'],
    do: scan_arbitrary_value(Text.skip_quoted_string(rest, q), st)

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

  @doc "Decodes an arbitrary value. Returns nil when the result is invalid or blank."
  @spec decode_valid_arbitrary_value(value :: String.t()) :: String.t() | nil
  def decode_valid_arbitrary_value(input) do
    value = decode_arbitrary_value(input)
    if valid_arbitrary_value?(value) and String.trim(value) != "", do: value
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
          [first | others] = Text.split_top_level(inner, ",")

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
end
