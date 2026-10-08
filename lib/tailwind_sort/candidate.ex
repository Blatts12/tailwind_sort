defmodule TailwindSort.Candidate do
  # Port of parseCandidate, findRoots and parseModifier from tailwindcss/src/candidate.ts.
  @moduledoc false

  alias TailwindSort.Text
  alias TailwindSort.Variant

  @named ~r/^[a-zA-Z0-9_.%-]+$/

  @doc """
  Returns `{variants, parses}`, or nil when Tailwind rejects the class. `parses` lists every
  possible base utility. Tailwind tries each one and keeps all that compile.
  """
  def parse_candidate(raw, d) do
    with {:ok, segments} <- strip_prefix(Text.split_top_level(raw, ":"), d.prefix),
         {base, raw_variants} = List.pop_at(segments, -1),
         {:ok, variants} <- parse_variants(raw_variants, d),
         {base, _important} = strip_important(base),
         [_ | _] = parses <- parse_base(base, d) do
      {variants, parses}
    else
      _ -> nil
    end
  end

  defp strip_prefix(segments, nil), do: {:ok, segments}
  defp strip_prefix([prefix, _ | _] = segs, prefix), do: {:ok, tl(segs)}
  defp strip_prefix(_, _), do: :error

  defp parse_variants(raws, d) do
    Enum.reduce_while(raws, {:ok, []}, fn raw, {:ok, acc} ->
      case Variant.parse_variant(raw, d) do
        nil -> {:halt, :error}
        v -> {:cont, {:ok, [v | acc]}}
      end
    end)
  end

  defp strip_important(base) do
    cond do
      String.ends_with?(base, "!") -> {binary_part(base, 0, byte_size(base) - 1), true}
      String.starts_with?(base, "!") -> {binary_part(base, 1, byte_size(base) - 1), true}
      true -> {base, false}
    end
  end

  defp parse_base(base, d) do
    static =
      if MapSet.member?(d.static, base) and not String.contains?(base, "["),
        do: [{:static, base}],
        else: []

    static ++ parse_dynamic_utility(base, d)
  end

  defp parse_dynamic_utility(base, d) do
    with [base_wo_mod | mod_rest] when length(mod_rest) <= 1 <- Text.split_top_level(base, "/"),
         mod_segment = List.first(mod_rest),
         {:ok, modifier} <- parse_modifier_segment(mod_segment) do
      if String.starts_with?(base_wo_mod, "[") do
        parse_arbitrary_property(base_wo_mod, modifier)
      else
        base_wo_mod
        |> find_utility_roots(d)
        |> build_functional_parses(modifier, mod_segment, [])
      end
    else
      _ -> []
    end
  end

  defp parse_modifier_segment(nil), do: {:ok, nil}

  defp parse_modifier_segment(seg) do
    case parse_modifier(seg) do
      nil -> :error
      m -> {:ok, m}
    end
  end

  defp parse_arbitrary_property(b, modifier) do
    with true <- String.ends_with?(b, "]"),
         <<?[, c, _::binary>> when c == ?- or c in ?a..?z <- b,
         inner = binary_part(b, 1, byte_size(b) - 2),
         {idx, _} when idx > 0 and idx < byte_size(inner) - 1 <- :binary.match(inner, ":"),
         property = binary_part(inner, 0, idx),
         value =
           Text.decode_arbitrary_value(binary_part(inner, idx + 1, byte_size(inner) - idx - 1)),
         true <- Text.valid_arbitrary_value?(value) do
      [{:arbitrary, property, value, modifier}]
    else
      _ -> []
    end
  end

  defp find_utility_roots(b, d) do
    root_registered? = &MapSet.member?(d.functional_roots, &1)

    cond do
      String.ends_with?(b, "]") ->
        case :binary.match(b, "-[") do
          {i, _} ->
            root = binary_part(b, 0, i)

            if root_registered?.(root),
              do: [{root, binary_part(b, i + 1, byte_size(b) - i - 1)}],
              else: []

          :nomatch ->
            []
        end

      String.ends_with?(b, ")") ->
        with {i, _} <- :binary.match(b, "-("),
             root = binary_part(b, 0, i),
             true <- root_registered?.(root),
             value = binary_part(b, i + 2, byte_size(b) - i - 3),
             {type, value} <- split_var_shorthand(Text.split_top_level(value, ":")),
             "--" <> _ <- value,
             true <- Text.valid_arbitrary_value?(value) do
          [{root, if(type, do: "[#{type}:var(#{value})]", else: "[var(#{value})]")}]
        else
          _ -> []
        end

      true ->
        find_roots(b, root_registered?)
    end
  end

  defp split_var_shorthand([type, value]), do: {type, value}
  defp split_var_shorthand([value]), do: {nil, value}
  defp split_var_shorthand(_), do: nil

  # Mirrors the generator loop in candidate.ts. A `continue` there skips one root, and a `return` stops them all.
  defp build_functional_parses([], _modifier, _seg, acc), do: Enum.reverse(acc)

  defp build_functional_parses([{root, nil} | rest], modifier, seg, acc),
    do: build_functional_parses(rest, modifier, seg, [{:functional, root, nil, modifier} | acc])

  defp build_functional_parses([{root, value} | rest], modifier, seg, acc) do
    case :binary.match(value, "[") do
      {start, _} ->
        if String.ends_with?(value, "]") do
          case parse_arbitrary_value(binary_part(value, start + 1, byte_size(value) - start - 2)) do
            nil ->
              build_functional_parses(rest, modifier, seg, acc)

            v ->
              build_functional_parses(rest, modifier, seg, [
                {:functional, root, v, modifier} | acc
              ])
          end
        else
          Enum.reverse(acc)
        end

      :nomatch ->
        if Regex.match?(@named, value),
          do:
            build_functional_parses(rest, modifier, seg, [
              {:functional, root, {:named, value}, modifier} | acc
            ]),
          else: build_functional_parses(rest, modifier, seg, acc)
    end
  end

  defp parse_arbitrary_value(raw) do
    v = Text.decode_arbitrary_value(raw)

    if Text.valid_arbitrary_value?(v) do
      {hint, v} =
        case Regex.run(~r/^([a-z-]*):(.*)$/s, v) do
          [_, hint, rest] -> {hint, rest}
          nil -> {nil, v}
        end

      if hint == "" or String.trim(v) == "", do: nil, else: {:arbitrary, hint, v}
    end
  end

  @doc "Port of parseModifier. Returns `{:named, v}`, `{:arbitrary, v}`, `{:var, v}` or nil."
  def parse_modifier("[" <> _ = m) do
    if String.ends_with?(m, "]") do
      v = Text.decode_arbitrary_value(binary_part(m, 1, byte_size(m) - 2))
      if Text.valid_arbitrary_value?(v) and String.trim(v) != "", do: {:arbitrary, v}
    else
      parse_named_modifier(m)
    end
  end

  def parse_modifier("(" <> _ = m) do
    if String.ends_with?(m, ")") do
      inner = binary_part(m, 1, byte_size(m) - 2)

      if String.starts_with?(inner, "--") and Text.valid_arbitrary_value?(inner),
        do: {:var, "var(#{inner})"}
    else
      parse_named_modifier(m)
    end
  end

  def parse_modifier(m), do: parse_named_modifier(m)

  defp parse_named_modifier(m), do: if(Regex.match?(@named, m), do: {:named, m})

  @doc "Port of findRoots. Returns every `{root, value}` split where `root` is registered."
  def find_roots(input, root_exists?) do
    whole = if root_exists?.(input), do: [{input, nil}], else: []

    dashes = for {i, 1} <- :binary.matches(input, "-"), i > 0, do: i

    {splits, _} =
      dashes
      |> Enum.reverse()
      |> Enum.reduce_while({[], nil}, fn idx, {acc, _} ->
        root = binary_part(input, 0, idx)
        value = binary_part(input, idx + 1, byte_size(input) - idx - 1)

        cond do
          not root_exists?.(root) -> {:cont, {acc, nil}}
          value == "" -> {:halt, {acc, nil}}
          root == "@" -> {:halt, {acc, nil}}
          true -> {:cont, {[{root, value} | acc], nil}}
        end
      end)

    at =
      if String.starts_with?(input, "@") and root_exists?.("@"),
        do: [{"@", binary_part(input, 1, byte_size(input) - 1)}],
        else: []

    whole ++ Enum.reverse(splits, at)
  end
end
