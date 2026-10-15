defmodule TailwindSort.Candidate.Functional do
  @moduledoc """
  Parses a functional utility like `bg-red-500`, `bg-[#fff]` or `bg-(--brand)` into its root and value.

  A class can split into a root and value in more than one way. `p-x-4` could be `p` + `x-4` or
  `p-x` + `4`. We return every split whose root Tailwind knows, in Tailwind's order.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.Design
  alias TailwindSort.Text
  alias TailwindSort.Text.ArbitraryValue

  @doc "Returns every functional parse of `base`, a class without variants or modifier."
  @spec parse_functional_utility(base :: String.t(), Candidate.modifier(), Design.t()) :: [Candidate.parse()]
  def parse_functional_utility(base, modifier, d) do
    base
    |> find_utility_roots(d)
    |> build_functional_parses(modifier, [])
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
        Candidate.find_roots(b, root_registered?)
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
         true <- ArbitraryValue.valid_arbitrary_value?(var) do
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
    v = ArbitraryValue.decode_arbitrary_value(raw)

    if ArbitraryValue.valid_arbitrary_value?(v) do
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
end
