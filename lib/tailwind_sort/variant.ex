defmodule TailwindSort.Variant do
  @moduledoc """
  Parses variants like `hover:` or `md:` and decides which one sorts first.

  This is a port of `parseVariant` from `candidate.ts`, `Variants#compare` and `compoundsWith`
  from `variants.ts`, and `compareBreakpoints` from `utils/compare-breakpoints.ts`.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.Design
  alias TailwindSort.Text

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

    with false <- String.starts_with?(inner, "@") and String.contains?(inner, "&"),
         selector = Text.decode_arbitrary_value(inner),
         true <- Text.valid_arbitrary_value?(selector),
         true <- String.trim(selector) != "" do
      relative = String.first(selector) in [">", "+", "~"]

      selector =
        if not relative and not String.starts_with?(selector, "@") and
             not String.contains?(selector, "&"),
           do: "&:is(#{selector})",
           else: selector

      %{kind: :arbitrary, raw: raw, selector: selector, relative: relative}
    else
      _ -> nil
    end
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
    case {d.variants[root].kind, value} do
      {:static, nil} when mod == nil ->
        %{kind: :static, root: root, raw: raw}

      {:static, _} ->
        nil

      {:functional, nil} ->
        build_with_modifier(
          mod,
          &%{kind: :functional, root: root, raw: raw, value: nil, modifier: &1}
        )

      {:functional, value} ->
        case parse_functional_value(value) do
          :continue ->
            try_roots(rest, mod, raw, d)

          nil ->
            nil

          v ->
            build_with_modifier(
              mod,
              &%{kind: :functional, root: root, raw: raw, value: v, modifier: &1}
            )
        end

      {:compound, nil} ->
        nil

      {:compound, value} ->
        {value, mod} =
          if mod && root in ~w(not has in), do: {"#{value}/#{mod}", nil}, else: {value, mod}

        with sub when sub != nil <- parse_variant(value, d),
             true <- compounds_with?(root, sub, d) do
          build_with_modifier(
            mod,
            &%{kind: :compound, root: root, raw: raw, variant: sub, modifier: &1}
          )
        else
          _ -> nil
        end
    end
  end

  defp build_with_modifier(nil, build_variant), do: build_variant.(nil)

  defp build_with_modifier(mod, build_variant) do
    case Candidate.parse_modifier(mod) do
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
    v = Text.decode_arbitrary_value(binary_part(value, 1, byte_size(value) - 2))

    cond do
      not Text.valid_arbitrary_value?(v) or String.trim(v) == "" -> nil
      form == :var and not String.starts_with?(v, "--") -> nil
      form == :var -> {:arbitrary, "var(#{v})", :var}
      true -> {:arbitrary, v, :arb}
    end
  end

  @spec compounds_with?(parent_root :: String.t(), child :: t(), Design.t()) :: boolean()
  def compounds_with?(parent, child, d) do
    child_compounds =
      case child do
        %{kind: :arbitrary, selector: s} -> Design.compute_selector_compounds([s])
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

  @doc "Port of Variants#compare. The raw string is the identity, because Tailwind caches variants by it."
  @spec compare_variants(t(), t(), Design.t()) :: integer()
  def compare_variants(%{raw: r}, %{raw: r}, _d), do: 0

  def compare_variants(%{kind: :arbitrary} = a, %{kind: :arbitrary} = z, _d),
    do: if(a.selector < z.selector, do: -1, else: 1)

  def compare_variants(%{kind: :arbitrary}, _, _d), do: 1
  def compare_variants(_, %{kind: :arbitrary}, _d), do: -1

  def compare_variants(a, z, d) do
    ao = d.variants[a.root].order
    zo = d.variants[z.root].order

    cond do
      ao != zo ->
        ao - zo

      a.kind == :compound and z.kind == :compound ->
        case compare_variants(a.variant, z.variant, d) do
          0 -> compare_modifiers(a.modifier, z.modifier)
          c -> c
        end

      cmp = d.variant_cmp[ao] ->
        compare_breakpoint_variants(a, z, cmp, d)

      a.root != z.root ->
        if a.root < z.root, do: -1, else: 1

      true ->
        compare_values(a.value, z.value)
    end
  end

  defp compare_modifiers(nil, nil), do: 0
  defp compare_modifiers(_, nil), do: 1
  defp compare_modifiers(nil, _), do: -1
  defp compare_modifiers({_, a}, {_, z}), do: if(a < z, do: -1, else: 1)

  defp compare_values(nil, _), do: -1
  defp compare_values(_, nil), do: 1
  defp compare_values({:arbitrary, _, _}, {:named, _}), do: 1
  defp compare_values({:named, _}, {:arbitrary, _, _}), do: -1
  defp compare_values(a, z), do: if(elem(a, 1) < elem(z, 1), do: -1, else: 1)

  defp compare_breakpoint_variants(a, z, {ns, dir}, d) do
    av = resolve_width(a, ns, d)
    zv = resolve_width(z, ns, d)

    cond do
      av == nil -> if dir == :asc, do: -1, else: 1
      zv == nil -> if dir == :asc, do: 1, else: -1
      true -> compare_breakpoints(av, zv, dir)
    end
  end

  defp resolve_width(%{kind: :static, root: root}, :breakpoint, d), do: d.theme["--breakpoint-#{root}"]

  defp resolve_width(%{kind: :functional, modifier: m}, :breakpoint, _d) when m != nil, do: nil
  defp resolve_width(%{kind: :functional, value: nil}, _ns, _d), do: nil

  defp resolve_width(%{kind: :functional, value: value}, ns, d) do
    v =
      case value do
        {:arbitrary, v, _} -> v
        {:named, n} -> d.theme["--#{ns}-#{n}"]
      end

    if v in [nil, ""] or String.contains?(v, "var("), do: nil, else: v
  end

  defp resolve_width(_, _, _), do: nil

  @doc false
  @spec compare_breakpoints(String.t(), String.t(), :asc | :desc) :: integer()
  def compare_breakpoints(a, a, _dir), do: 0

  def compare_breakpoints(a, z, dir) do
    order =
      case {to_unit_bucket(a), to_unit_bucket(z)} do
        {b, b} -> diff_parsed_ints(a, z, dir)
        {ab, zb} -> if ab < zb, do: -1, else: 1
      end

    if order == :nan, do: if(a < z, do: -1, else: 1), else: order
  end

  defp to_unit_bucket(v) do
    case :binary.match(v, "(") do
      :nomatch -> for <<c <- v>>, c not in ?0..?9 and c != ?., into: "", do: <<c>>
      {i, _} -> binary_part(v, 0, i)
    end
  end

  defp diff_parsed_ints(a, z, dir) do
    with {ai, _} <- parse_int_like_js(a), {zi, _} <- parse_int_like_js(z) do
      if dir == :asc, do: ai - zi, else: zi - ai
    else
      _ -> :nan
    end
  end

  defp parse_int_like_js(v), do: v |> String.trim_leading() |> Integer.parse()
end
