defmodule TailwindSort.Utility do
  @moduledoc """
  Works out where a base utility like `text-lg` lands in Tailwind's CSS order.

  It resolves a parsed utility to its property sort, `{property_indices, declaration_count}`.
  That's what Tailwind's `getPropertySort` computes from the generated CSS. We return `nil`
  when Tailwind would generate nothing. The answers come from data generated against the real
  design system:

    * `exact` holds every class from `getClassList()`, like `"text-lg"`, plus the theme vars it
      uses.
    * `functional` holds the result for each kind of value, per root. The kinds are bare
      numbers, a key in some theme namespace, arbitrary values grouped by inferred data type,
      and hints.
    * `modifiers` holds the effect of each kind of modifier, per root, value group and
      signature. It points into `modifier_tables` by index, because many groups share the same
      table.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.DataType
  alias TailwindSort.Design
  alias TailwindSort.Text

  @type signature :: {[non_neg_integer()], non_neg_integer()}

  @spec compute_signature(Candidate.parse(), Design.t()) :: signature() | nil
  def compute_signature({:static, name}, d) do
    pick_min_signature([
      d.exact[name] && elem(d.exact[name], 0) | Map.get(d.custom_static, name, [])
    ])
  end

  def compute_signature({:arbitrary, property, _value, modifier}, d) do
    if modifier_ok_for_color?(modifier) do
      {List.wrap(d.property_index[property]), 1}
    end
  end

  def compute_signature({:functional, root, value, modifier} = parse, d) do
    custom =
      for {sig, rules} <- Map.get(d.custom_functional, root, []),
          custom_utility_accepts?(rules, value, modifier, d),
          do: sig

    pick_min_signature([compute_core_signature(parse, d) | custom])
  end

  defp custom_utility_accepts?(:icon, value, modifier, _d), do: match?({:named, _}, value) and modifier == nil

  defp custom_utility_accepts?(_rules, nil, _modifier, _d), do: false

  defp custom_utility_accepts?(rules, value, modifier, d),
    do: (modifier == nil or rules.modifier) and rules_accept_value?(value, rules, d)

  defp rules_accept_value?(_value, %{any_value: true}, _d), do: true

  defp rules_accept_value?({:named, v}, rules, d) do
    v in rules.literal or Enum.any?(rules.ns, &Design.theme_has_key?(d, &1, v)) or
      Enum.any?(rules.bare, fn
        "any" -> true
        "integer" -> Text.digits?(v)
        "number" -> quarter_multiple?(v) or Text.digits?(v)
        "percentage" -> percent_value?(v, &Text.digits?/1)
        "ratio" -> false
      end)
  end

  defp rules_accept_value?({:arbitrary, hint, v}, rules, d) do
    types = DataType.infer_types(v, d.named_colors)

    Enum.any?(rules.arbitrary, fn
      "*" -> true
      t -> if hint, do: hint == t, else: types != :var and MapSet.member?(types, t)
    end)
  end

  defp compute_core_signature({:functional, root, {:named, v}, modifier}, d) do
    key = "#{root}-#{v}"

    case d.exact[key] do
      {sig, deps} ->
        if deps == [] or Enum.any?(deps, &Map.has_key?(d.theme, &1)) do
          group = if deps == [], do: to_value_group(v, d), else: :theme
          apply_modifier(sig, root, group, modifier, d, Map.get(d.exact_modifiers, key))
        else
          lookup_named_value(root, v, modifier, d)
        end

      nil ->
        lookup_named_value(root, v, modifier, d)
    end
  end

  defp compute_core_signature({:functional, root, nil, modifier}, d),
    do: lookup_functional(root, :none, :none, modifier, d)

  defp compute_core_signature({:functional, root, {:arbitrary, hint, v}, modifier}, d) do
    vclass =
      cond do
        hint && MapSet.member?(d.hints, hint) -> {:hint, hint}
        hint -> {:hint, "zzqhint"}
        true -> {:arb, find_corpus_index(v, d)}
      end

    lookup_functional(root, vclass, vclass, modifier, d)
  end

  defp lookup_named_value(root, v, modifier, d) do
    case Enum.find(Map.get(d.ns_priority, root, []), &Design.theme_has_key?(d, &1, v)) do
      nil ->
        group = to_value_group(v, d)
        lookup_functional(root, group, group, modifier, d)

      ns ->
        lookup_functional(root, {:ns, ns}, :theme, modifier, d)
    end
  end

  # Mirrors toValueGroup() in scripts/extract.mjs.
  defp to_value_group("0", _d), do: :zero

  defp to_value_group(v, d) do
    cond do
      Text.digits?(v) -> :int
      Text.decimal?(v) -> if(quarter_multiple?(v), do: :dec25, else: :dec)
      percent_value?(v, &Text.digits?/1) -> :pct
      percent_value?(v, &Text.decimal?/1) -> :pctdec
      MapSet.member?(d.keywords, v) -> {:kw, v}
      true -> :word
    end
  end

  defp percent_value?(v, number?), do: String.ends_with?(v, "%") and number?.(binary_part(v, 0, byte_size(v) - 1))

  # Port of isValidSpacingMultiplier. The value must be a multiple of 0.25, written the way JS prints numbers.
  defp quarter_multiple?(v) do
    case Float.parse(v) do
      {f, ""} -> Float.to_string(f) == v and f * 4 == Float.round(f * 4)
      _ -> false
    end
  end

  # A base can be invalid alone yet valid with a modifier. Fractions like `aspect-13/2.5` work that way.
  defp lookup_functional(root, vclass, group, modifier, d) do
    case d.functional[root] do
      %{^vclass => sig} -> apply_modifier(sig, root, group, modifier, d, nil)
      _ when modifier != nil -> apply_modifier(nil, root, group, modifier, d, nil)
      _ -> nil
    end
  end

  defp apply_modifier(sig, _root, _group, nil, _d, _overrides), do: sig

  defp apply_modifier(sig, root, group, modifier, d, overrides) do
    table =
      case d.modifiers do
        %{{^root, ^group, ^sig} => i} -> elem(d.modifier_tables, i)
        _ -> %{}
      end

    mclass = classify_modifier(modifier, Map.merge(table, overrides || %{}), d)

    result =
      case overrides do
        %{^mclass => r} -> r
        _ -> Map.get(table, mclass, :invalid)
      end

    if result == :invalid, do: nil, else: result
  end

  defp classify_modifier({:arbitrary, _}, _table, _d), do: :arb
  defp classify_modifier({:var, _}, _table, _d), do: :var

  defp classify_modifier({:named, m}, table, d) do
    ns =
      Enum.find_value(table, fn
        {{:ns, ns} = k, _} -> if Design.theme_has_key?(d, ns, m), do: k
        _ -> nil
      end)

    cond do
      ns -> ns
      Text.digits?(m) -> :int
      Text.decimal?(m) -> if(quarter_multiple?(m), do: :dec25, else: :dec)
      true -> :word
    end
  end

  defp find_corpus_index(value, d) do
    types = DataType.infer_types(value, d.named_colors)

    case d.corpus_by_types do
      %{^types => i} -> i
      by_types -> find_closest_corpus_index(types, by_types)
    end
  end

  # No corpus value has exactly this type set, so we take the one sharing the most types.
  defp find_closest_corpus_index(:var, by_types), do: Map.get(by_types, :var)

  defp find_closest_corpus_index(types, by_types) do
    by_types
    |> Enum.reject(fn {t, _} -> t == :var end)
    |> Enum.max_by(fn {t, _} -> {MapSet.size(MapSet.intersection(t, types)), -MapSet.size(t)} end)
    |> elem(1)
  end

  defp modifier_ok_for_color?(nil), do: true
  defp modifier_ok_for_color?({:named, m}), do: Text.digits?(m) or Text.decimal?(m)
  defp modifier_ok_for_color?(_), do: true

  @doc "Port of the per-rule comparator in compile.ts. It leaves out variants and the class name."
  @spec compare_signatures(signature(), signature()) :: integer()
  def compare_signatures({ao, ac}, {zo, zc}) do
    case find_first_diff(ao, zo) do
      0 -> zc - ac
      diff -> diff
    end
  end

  defp find_first_diff([x | a], [x | z]), do: find_first_diff(a, z)
  defp find_first_diff([], []), do: 0
  defp find_first_diff([], _), do: 1
  defp find_first_diff(_, []), do: -1
  defp find_first_diff([a | _], [z | _]), do: a - z

  defp pick_min_signature(sigs) do
    sigs
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn a, z -> compare_signatures(a, z) <= 0 end, fn -> nil end)
  end
end
