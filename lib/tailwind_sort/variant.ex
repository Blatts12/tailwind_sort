defmodule TailwindSort.Variant do
  @moduledoc """
  Parses variants like `hover:` or `md:` and checks that Tailwind would generate CSS for them.

  This is a port of `parseVariant` from `candidate.ts` and `compoundsWith` from `variants.ts`.
  `TailwindSort.Variant.Order` decides which variant sorts first.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.Candidate.Modifier
  alias TailwindSort.Design
  alias TailwindSort.Design.VariantTable
  alias TailwindSort.Text
  alias TailwindSort.Text.ArbitraryValue

  @type t :: %{
          required(:kind) => :static | :functional | :compound | :arbitrary,
          required(:raw) => String.t(),
          optional(atom()) => term()
        }

  @doc "Parses a variant string. Returns nil when Tailwind would reject it."
  @spec parse_variant(variant :: String.t(), Design.t()) :: t() | nil
  def parse_variant(raw, %Design{} = d) do
    if String.starts_with?(raw, "[") and String.ends_with?(raw, "]"),
      do: parse_arbitrary_variant(raw),
      else: parse_named_variant(raw, d)
  end

  defp parse_arbitrary_variant(raw) do
    inner = binary_part(raw, 1, byte_size(raw) - 2)

    if at_rule_with_ampersand?(inner),
      do: nil,
      else: inner |> ArbitraryValue.decode_valid_arbitrary_value() |> build_arbitrary_variant(raw)
  end

  defp at_rule_with_ampersand?(inner), do: String.starts_with?(inner, "@") and String.contains?(inner, "&")

  defp build_arbitrary_variant(nil, _raw), do: nil

  defp build_arbitrary_variant(selector, raw) do
    relative = String.first(selector) in [">", "+", "~"]

    selector =
      if not relative and not String.starts_with?(selector, "@") and
           not String.contains?(selector, "&"),
         do: "&:is(#{selector})",
         else: selector

    %{kind: :arbitrary, raw: raw, selector: selector, relative: relative}
  end

  defp parse_named_variant(raw, d) do
    case Text.split_top_level(raw, "/") do
      [_, _, _ | _] ->
        nil

      [base] ->
        try_roots(Candidate.find_roots(base, &Map.has_key?(d.variants, &1)), nil, raw, d)

      [base, mod] ->
        try_roots(Candidate.find_roots(base, &Map.has_key?(d.variants, &1)), mod, raw, d)
    end
  end

  defp try_roots([], _mod, _raw, _d), do: nil

  defp try_roots([{root, value} | rest], mod, raw, d) do
    variant =
      case {d.variants[root].kind, value} do
        {:static, nil} when mod == nil -> %{kind: :static, root: root, raw: raw}
        {:static, _} -> nil
        {:functional, value} -> build_functional_variant(root, value, mod, raw)
        {:compound, nil} -> nil
        {:compound, value} -> build_compound_variant(root, value, mod, raw, d)
      end

    if variant == :continue, do: try_roots(rest, mod, raw, d), else: variant
  end

  defp build_functional_variant(root, nil, mod, raw),
    do: build_with_modifier(mod, &%{kind: :functional, root: root, raw: raw, value: nil, modifier: &1})

  defp build_functional_variant(root, value, mod, raw) do
    case parse_functional_value(value) do
      :continue -> :continue
      nil -> nil
      v -> build_with_modifier(mod, &%{kind: :functional, root: root, raw: raw, value: v, modifier: &1})
    end
  end

  # `not`, `has` and `in` hand their modifier down to the variant inside them.
  defp build_compound_variant(root, value, mod, raw, d) do
    {value, mod} = if mod && root in ~w(not has in), do: {"#{value}/#{mod}", nil}, else: {value, mod}
    sub = parse_variant(value, d)

    if sub && compounds_with?(root, sub, d),
      do: build_with_modifier(mod, &%{kind: :compound, root: root, raw: raw, variant: sub, modifier: &1})
  end

  defp build_with_modifier(nil, build_variant), do: build_variant.(nil)

  defp build_with_modifier(mod, build_variant) do
    case Modifier.parse_modifier(mod) do
      nil -> nil
      m -> build_variant.(m)
    end
  end

  defp parse_functional_value(value) do
    cond do
      String.ends_with?(value, "]") ->
        if String.starts_with?(value, "["),
          do: parse_arbitrary_value(value, :arb),
          else: :continue

      String.ends_with?(value, ")") ->
        if String.starts_with?(value, "("),
          do: parse_arbitrary_value(value, :var),
          else: :continue

      Text.named_value?(value) ->
        {:named, value}

      true ->
        :continue
    end
  end

  defp parse_arbitrary_value(value, form) do
    case ArbitraryValue.decode_valid_arbitrary_value(binary_part(value, 1, byte_size(value) - 2)) do
      nil -> nil
      "--" <> _ = v when form == :var -> {:arbitrary, "var(#{v})", :var}
      _ when form == :var -> nil
      v -> {:arbitrary, v, :arb}
    end
  end

  @spec compounds_with?(parent_root :: String.t(), child :: t(), Design.t()) :: boolean()
  def compounds_with?(parent, child, d) do
    child_compounds =
      case child do
        %{kind: :arbitrary, selector: s} -> VariantTable.compute_selector_compounds([s])
        %{root: r} -> d.variants[r].compounds
      end

    p = d.variants[parent]

    p.kind == :compound and child_compounds != 0 and p.compounds_with != 0 and
      Bitwise.band(p.compounds_with, child_compounds) != 0
  end

  @doc "Checks whether applying the variant produces CSS, like `applyVariant != null` in Tailwind."
  @spec produces_css?(t(), Design.t(), non_neg_integer()) :: boolean()
  def produces_css?(variant, d, depth \\ 0)
  def produces_css?(%{kind: :arbitrary, relative: rel}, _d, depth), do: not (rel and depth == 0)
  def produces_css?(%{kind: :static}, _d, _depth), do: true

  def produces_css?(%{kind: :compound, variant: sub} = v, d, depth) do
    produces_css?(sub, d, depth + 1) and chain_allowed?(to_compound_chain(v), d)
  end

  def produces_css?(%{kind: :functional, root: root, value: value, modifier: mod}, d, _depth) do
    rules = Map.get(d.functional_variant_rules, root, %{})

    rule_allows? = fn form ->
      elem(Map.get(rules, form, {false, false}), if(mod, do: 1, else: 0))
    end

    case value do
      nil ->
        rule_allows?.(:none)

      {:arbitrary, v, :arb} ->
        rule_allows?.(if String.contains?(v, "var("), do: :arbvar, else: :arb)

      {:arbitrary, _, :var} ->
        rule_allows?.(:var)

      {:named, v} ->
        theme_hit =
          Enum.any?(rules, fn
            {{:ns, ns}, _} = rule ->
              Design.theme_has_key?(d, ns, v) and rule_allows?.(elem(rule, 0))

            _ ->
              false
          end)

        theme_hit or rule_allows?.(if Text.digits?(v), do: :int, else: :word)
    end
  end

  # Tailwind rejects some compound chains at compile time, like group-not-hover. Probes told us which.
  defp to_compound_chain(%{kind: :compound, root: r, variant: sub}), do: [r | to_compound_chain(sub)]

  defp to_compound_chain(%{kind: :arbitrary, relative: true}), do: ["[rel]"]
  defp to_compound_chain(%{kind: :arbitrary, selector: "@" <> _}), do: ["[at]"]
  defp to_compound_chain(%{kind: :arbitrary}), do: ["[sel]"]
  defp to_compound_chain(%{root: r}), do: [r]

  defp chain_allowed?(chain, d) do
    if MapSet.member?(d.custom_variants, List.last(chain)),
      do: true,
      else: Map.get(d.compound_chains, chain, true)
  end
end
