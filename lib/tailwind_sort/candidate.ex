defmodule TailwindSort.Candidate do
  @moduledoc """
  Splits a class like `md:hover:bg-red-500/50` into its variants and its base utility.

  This is a port of `parseCandidate`, `findRoots` and `parseModifier` from
  `tailwindcss/src/candidate.ts`. A class Tailwind would reject parses to `nil`.
  """

  alias TailwindSort.Design
  alias TailwindSort.Text
  alias TailwindSort.Variant

  @type modifier :: {:named | :arbitrary | :var, String.t()} | nil
  @type value :: {:named, String.t()} | {:arbitrary, String.t() | nil, String.t()} | nil

  @type parse ::
          {:static, String.t()}
          | {:arbitrary, String.t(), String.t(), modifier()}
          | {:functional, String.t(), value(), modifier()}

  @doc """
  Returns `{variants, parses}`, or nil when Tailwind rejects the class. `parses` lists every
  possible base utility. Tailwind tries each one and keeps all that compile.
  """
  @spec parse_candidate(class :: String.t(), Design.t()) :: {[Variant.t()], [parse(), ...]} | nil
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
  defp strip_prefix([prefix, _ | _] = segments, prefix), do: {:ok, tl(segments)}
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
    with {:ok, base_wo_mod, mod_segment} <- split_modifier(base),
         {:ok, modifier} <- parse_modifier_segment(mod_segment) do
      if String.starts_with?(base_wo_mod, "[") do
        parse_arbitrary_property(base_wo_mod, modifier)
      else
        base_wo_mod
        |> find_utility_roots(d)
        |> build_functional_parses(modifier, [])
      end
    else
      :error -> []
    end
  end

  defp split_modifier(base) do
    case Text.split_top_level(base, "/") do
      [base_wo_mod] -> {:ok, base_wo_mod, nil}
      [base_wo_mod, mod_segment] -> {:ok, base_wo_mod, mod_segment}
      _ -> :error
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
    with {:ok, inner} <- unwrap_property_brackets(b),
         {:ok, property, raw_value} <- split_property_and_value(inner),
         {:ok, value} <- decode_and_validate_value(raw_value) do
      [{:arbitrary, property, value, modifier}]
    else
      :error -> []
    end
  end

  defp unwrap_property_brackets(<<?[, c, _::binary>> = b) when c == ?- or c in ?a..?z do
    if String.ends_with?(b, "]"), do: {:ok, binary_part(b, 1, byte_size(b) - 2)}, else: :error
  end

  defp unwrap_property_brackets(_), do: :error

  defp split_property_and_value(inner) do
    case :binary.split(inner, ":") do
      [property, raw_value] when property != "" and raw_value != "" -> {:ok, property, raw_value}
      _ -> :error
    end
  end

  defp decode_and_validate_value(raw_value) do
    value = Text.decode_arbitrary_value(raw_value)
    if Text.valid_arbitrary_value?(value), do: {:ok, value}, else: :error
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
        with {:ok, root, inner} <- split_root_and_parens(b),
             true <- root_registered?.(root),
             {:ok, value} <- expand_var_shorthand(inner) do
          [{root, value}]
        else
          _ -> []
        end

      true ->
        find_roots(b, root_registered?)
    end
  end

  defp split_root_and_parens(b) do
    case :binary.split(b, "-(") do
      [root, rest] -> {:ok, root, binary_part(rest, 0, byte_size(rest) - 1)}
      [_] -> :error
    end
  end

  # `(--x)` stands for `[var(--x)]`, and `(color:--x)` for `[color:var(--x)]`.
  defp expand_var_shorthand(inner) do
    with {type, "--" <> _ = var} <- split_var_shorthand(Text.split_top_level(inner, ":")),
         true <- Text.valid_arbitrary_value?(var) do
      {:ok, "[#{type}var(#{var})]"}
    else
      _ -> :error
    end
  end

  defp split_var_shorthand([type, var]), do: {type <> ":", var}
  defp split_var_shorthand([var]), do: {"", var}
  defp split_var_shorthand(_), do: nil

  # Mirrors the generator loop in candidate.ts. A `continue` there skips one root, and a `return` stops them all.
  defp build_functional_parses([], _modifier, acc), do: Enum.reverse(acc)

  defp build_functional_parses([{root, value} | rest], modifier, acc) do
    case parse_root_value(value) do
      {:ok, v} -> build_functional_parses(rest, modifier, [{:functional, root, v, modifier} | acc])
      :skip -> build_functional_parses(rest, modifier, acc)
      :stop -> Enum.reverse(acc)
    end
  end

  defp parse_root_value(nil), do: {:ok, nil}

  defp parse_root_value(value) do
    case {:binary.match(value, "["), String.ends_with?(value, "]")} do
      {:nomatch, _} ->
        if Text.named_value?(value), do: {:ok, {:named, value}}, else: :skip

      {_, false} ->
        :stop

      {{start, _}, true} ->
        case parse_arbitrary_value(binary_part(value, start + 1, byte_size(value) - start - 2)) do
          nil -> :skip
          v -> {:ok, v}
        end
    end
  end

  defp parse_arbitrary_value(raw) do
    v = Text.decode_arbitrary_value(raw)

    if Text.valid_arbitrary_value?(v) do
      {hint, v} =
        case :binary.split(v, ":") do
          [hint, rest] -> if type_hint?(hint), do: {hint, rest}, else: {nil, v}
          [_] -> {nil, v}
        end

      if hint == "" or String.trim(v) == "", do: nil, else: {:arbitrary, hint, v}
    end
  end

  defp type_hint?(<<c, rest::binary>>) when c in ?a..?z or c == ?-, do: type_hint?(rest)
  defp type_hint?(rest), do: rest == ""

  @doc "Port of parseModifier. Returns `{:named, v}`, `{:arbitrary, v}`, `{:var, v}` or nil."
  @spec parse_modifier(modifier :: String.t()) :: modifier()
  def parse_modifier("[" <> _ = m) do
    if String.ends_with?(m, "]") do
      with v when v != nil <- Text.decode_valid_arbitrary_value(binary_part(m, 1, byte_size(m) - 2)),
           do: {:arbitrary, v}
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

  defp parse_named_modifier(m), do: if(Text.named_value?(m), do: {:named, m})

  @doc "Port of findRoots. Returns every `{root, value}` split where `root` is registered."
  @spec find_roots(input :: String.t(), root_exists? :: (String.t() -> boolean())) :: [{String.t(), String.t() | nil}]
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
